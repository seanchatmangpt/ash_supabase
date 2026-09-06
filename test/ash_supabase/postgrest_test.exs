defmodule AshSupabase.PostgRESTTest do
  use AshSupabase.Case, async: true

  alias AshSupabase.Error
  alias AshSupabase.PostgREST
  alias AshSupabase.PostgREST.Query

  describe "parse_count/1" do
    test "reads the total after the slash" do
      assert PostgREST.parse_count(%{"content-range" => ["0-24/3573"]}) == 3573
    end

    test "an empty result reports its range as an asterisk but still has a total" do
      assert PostgREST.parse_count(%{"content-range" => ["*/0"]}) == 0
    end

    test "an uncounted response reports the total as an asterisk, which is not zero" do
      assert PostgREST.parse_count(%{"content-range" => ["0-14/*"]}) == nil
    end

    test "a missing or malformed header yields nil rather than raising" do
      assert PostgREST.parse_count(%{}) == nil
      assert PostgREST.parse_count(%{"content-range" => ["nonsense"]}) == nil
      assert PostgREST.parse_count(%{"content-range" => []}) == nil
    end
  end

  describe "run/3" do
    test "does not make a request for a query that can never match" do
      Req.Test.stub(AshSupabase.Test.Client, fn _conn ->
        flunk("an impossible query should never reach the network")
      end)

      query = Query.new("posts") |> Query.add_filters(:impossible)

      assert {:ok, [], %{count: 0}} = PostgREST.run(AshSupabase.Test.Client, query)
    end

    test "returns rows and the parsed count" do
      capture =
        expect_request(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-range", "0-1/42")
          |> Req.Test.json([%{"id" => 1}])
        end)

      query = Query.new("posts") |> Query.count(:exact)

      assert {:ok, [%{"id" => 1}], %{count: 42}} =
               PostgREST.run(AshSupabase.Test.Client, query)

      assert capture.().method == "GET"
    end

    test "treats 206 Partial Content as success, which is what a counted page returns" do
      expect_request(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-range", "0-9/100")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(206, Jason.encode!([%{"id" => 1}]))
      end)

      assert {:ok, [_], %{count: 100, status: 206}} =
               PostgREST.run(AshSupabase.Test.Client, Query.new("posts"))
    end
  end

  describe "insert/4" do
    test "sends a bare object for a single row" do
      capture = expect_request(&Req.Test.json(&1, [%{"id" => 1}]))

      PostgREST.insert(AshSupabase.Test.Client, Query.new("posts"), %{"title" => "a"})

      conn = capture.()
      assert conn.method == "POST"
      assert request_body(conn) == %{"title" => "a"}
    end

    test "sends an array for a bulk insert" do
      capture = expect_request(&Req.Test.json(&1, []))

      PostgREST.insert(AshSupabase.Test.Client, Query.new("posts"), [
        %{"title" => "a"},
        %{"title" => "b"}
      ])

      assert request_body(capture.()) == [%{"title" => "a"}, %{"title" => "b"}]
    end
  end

  describe "destructive request guardrails" do
    test "refuses an unfiltered update, which would rewrite every row" do
      Req.Test.stub(AshSupabase.Test.Client, fn _conn ->
        flunk("an unfiltered update must not reach the network")
      end)

      assert {:error, %Error.Unsupported{} = error} =
               PostgREST.update(AshSupabase.Test.Client, Query.new("posts"), %{"a" => 1})

      message = Exception.message(error)
      assert message =~ "Refusing to update every row"
      assert message =~ "allow_unfiltered?"
    end

    test "refuses an unfiltered delete, which would empty the table" do
      Req.Test.stub(AshSupabase.Test.Client, fn _conn ->
        flunk("an unfiltered delete must not reach the network")
      end)

      assert {:error, %Error.Unsupported{}} =
               PostgREST.delete(AshSupabase.Test.Client, Query.new("posts"))
    end

    test "allows an unfiltered write when it is asked for explicitly" do
      capture = expect_request(&Req.Test.json(&1, []))

      assert {:ok, _, _} =
               PostgREST.delete(AshSupabase.Test.Client, Query.new("posts"),
                 allow_unfiltered?: true
               )

      assert capture.().method == "DELETE"
    end

    test "a filtered write proceeds without any opt-in" do
      capture = expect_request(&Req.Test.json(&1, []))

      query = Query.new("posts") |> Query.add_filters([{"id", "eq.1"}])

      assert {:ok, _, _} = PostgREST.delete(AshSupabase.Test.Client, query)
      assert capture.().method == "DELETE"
    end
  end

  describe "rpc/4" do
    test "POSTs a flat object keyed by parameter name" do
      capture = expect_request(&Req.Test.json(&1, 3))

      PostgREST.rpc(AshSupabase.Test.Client, "add_them", %{"a" => 1, "b" => 2})

      conn = capture.()
      assert conn.method == "POST"
      assert conn.request_path == "/rest/v1/rpc/add_them"
      assert request_body(conn) == %{"a" => 1, "b" => 2}
    end

    test "GET puts arguments in the query string, for immutable functions" do
      capture = expect_request(&Req.Test.json(&1, 3))

      PostgREST.rpc(AshSupabase.Test.Client, "add_them", %{"a" => 1}, method: :get)

      conn = capture.()
      assert conn.method == "GET"
      assert {"a", "1"} in query_params(conn)
    end

    test "a query shapes a set-returning function's result" do
      capture = expect_request(&Req.Test.json(&1, []))

      query = Query.new("ignored") |> Query.select([:title]) |> Query.limit(5)

      PostgREST.rpc(AshSupabase.Test.Client, "best_films", %{}, query: query)

      conn = capture.()
      assert conn.request_path == "/rest/v1/rpc/best_films"
      assert {"select", "title"} in query_params(conn)
      assert {"limit", "5"} in query_params(conn)
    end
  end

  describe "errors" do
    test "parses the PostgREST error object into a structured error" do
      expect_request(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{
            "code" => "PGRST100",
            "message" => "unexpected \"e\" expecting delimiter",
            "details" => "unexpected end of input",
            "hint" => nil
          })
        )
      end)

      assert {:error, %Error.Request{} = error} =
               PostgREST.run(AshSupabase.Test.Client, Query.new("posts"))

      assert error.status == 400
      assert error.code == "PGRST100"
      assert error.supabase_message =~ "expecting delimiter"
      assert error.details == "unexpected end of input"
      assert Exception.message(error) =~ "PGRST100"
    end

    test "forwards a SQLSTATE code as-is, so callers can branch on it" do
      expect_request(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          409,
          Jason.encode!(%{
            "code" => "23505",
            "message" => "duplicate key value violates unique constraint",
            "details" => nil,
            "hint" => nil
          })
        )
      end)

      assert {:error, %Error.Request{code: "23505", status: 409}} =
               PostgREST.insert(AshSupabase.Test.Client, Query.new("posts"), %{})
    end

    test "a transport failure is reported as such, not as a request error" do
      Req.Test.stub(AshSupabase.Test.Client, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Error.Transport{} = error} =
               PostgREST.run(AshSupabase.Test.Client, Query.new("posts"))

      assert Exception.message(error) =~ "Could not reach Supabase"
    end
  end
end
