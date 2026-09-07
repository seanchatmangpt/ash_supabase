defmodule AshSupabase.ClientTest do
  use AshSupabase.Case, async: true

  alias AshSupabase.Client
  alias AshSupabase.Config
  alias AshSupabase.Error

  describe "config/1" do
    test "resolves a client module" do
      assert {:ok, %Config{url: "https://test.supabase.co"}} =
               Client.config(AshSupabase.Test.Client)
    end

    test "accepts a keyword list" do
      assert {:ok, %Config{api_key: "k"}} =
               Client.config(url: "https://x.supabase.co", api_key: "k")
    end

    test "passes an existing config through" do
      config = Config.new!(url: "https://x.supabase.co", api_key: "k")
      assert {:ok, ^config} = Client.config(config)
    end

    test "explains what to do when the module is not a client" do
      assert {:error, %Error.Configuration{} = error} = Client.config(Enum)
      assert Exception.message(error) =~ "use AshSupabase.Client"
    end

    test "reports a missing module clearly" do
      assert {:error, %Error.Configuration{} = error} = Client.config(NoSuchModule)
      assert Exception.message(error) =~ "not a loaded module"
    end

    test "reports invalid settings" do
      assert {:error, %Error.Configuration{}} = Client.config(api_key: "k")
    end
  end

  describe "supabase_config/0 on the generated module" do
    test "returns the resolved config" do
      assert %Config{schema: "public"} = AshSupabase.Test.Client.supabase_config()
    end
  end

  describe "authentication headers" do
    test "sends the api key and a bearer token derived from it" do
      capture = expect_request(&Req.Test.json(&1, %{}))

      Client.request(AshSupabase.Test.Client, :get, "/rest/v1/posts")

      conn = capture.()
      assert header(conn, "apikey") == "test-anon-key"
      assert header(conn, "authorization") == "Bearer test-anon-key"
    end

    test "a per-request token overrides the bearer token but not the api key" do
      capture = expect_request(&Req.Test.json(&1, %{}))

      Client.request(AshSupabase.Test.Client, :get, "/rest/v1/posts", token: "user-jwt")

      conn = capture.()
      assert header(conn, "authorization") == "Bearer user-jwt"
      assert header(conn, "apikey") == "test-anon-key"
    end
  end

  describe "schema profile headers" do
    test "reads use Accept-Profile" do
      for method <- [:get, :head] do
        capture = expect_request(&Req.Test.json(&1, %{}))
        Client.request(AshSupabase.Test.Client, method, "/rest/v1/posts")
        conn = capture.()
        assert header(conn, "accept-profile") == "public"
        assert header(conn, "content-profile") == nil
      end
    end

    test "writes use Content-Profile" do
      for method <- [:post, :patch, :put, :delete] do
        capture = expect_request(&Req.Test.json(&1, %{}))
        Client.request(AshSupabase.Test.Client, method, "/rest/v1/posts", json: %{})
        conn = capture.()
        assert header(conn, "content-profile") == "public"
        assert header(conn, "accept-profile") == nil
      end
    end

    test "a per-request schema overrides the client's" do
      capture = expect_request(&Req.Test.json(&1, %{}))

      Client.request(AshSupabase.Test.Client, :get, "/rest/v1/posts", schema: "tenant_a")

      assert header(capture.(), "accept-profile") == "tenant_a"
    end
  end

  describe "header precedence" do
    test "a configured header cannot override the request's own authorization" do
      capture = expect_request(&Req.Test.json(&1, %{}))

      client = [
        url: "https://test.supabase.co",
        api_key: "anon",
        headers: [{"authorization", "Bearer stale-from-config"}, {"x-app", "mine"}],
        req_options: [plug: {Req.Test, AshSupabase.Test.Client}]
      ]

      Client.request(client, :get, "/rest/v1/posts", token: "user-jwt")

      conn = capture.()
      assert header(conn, "authorization") == "Bearer user-jwt"
      assert header(conn, "apikey") == "anon"
      # Headers that are not part of authentication still come through.
      assert header(conn, "x-app") == "mine"
    end

    test "a per-request header still overrides a configured one" do
      capture = expect_request(&Req.Test.json(&1, %{}))

      client = [
        url: "https://test.supabase.co",
        api_key: "anon",
        headers: [{"x-app", "from-config"}],
        req_options: [plug: {Req.Test, AshSupabase.Test.Client}]
      ]

      Client.request(client, :get, "/x", headers: [{"x-app", "from-request"}])

      assert header(capture.(), "x-app") == "from-request"
    end
  end

  describe "urls" do
    test "joins a relative path onto the project url" do
      capture = expect_request(&Req.Test.json(&1, %{}))

      Client.request(AshSupabase.Test.Client, :get, "/rest/v1/posts")

      assert capture.().request_path == "/rest/v1/posts"
    end

    test "leaves an absolute url alone" do
      capture = expect_request(&Req.Test.json(&1, %{}))

      Client.request(AshSupabase.Test.Client, :get, "https://test.supabase.co/other/path")

      assert capture.().request_path == "/other/path"
    end
  end

  describe "responses" do
    test "decodes a JSON body" do
      expect_request(&Req.Test.json(&1, %{"a" => 1}))

      assert {:ok, %{body: %{"a" => 1}, status: 200}} =
               Client.request(AshSupabase.Test.Client, :get, "/x")
    end

    test "leaves a non-JSON body untouched, so binaries survive intact" do
      bytes = <<0xFF, 0xD8, 0xFF, 0xE0>>

      expect_request(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("image/jpeg")
        |> Plug.Conn.send_resp(200, bytes)
      end)

      assert {:ok, %{body: ^bytes}} = Client.request(AshSupabase.Test.Client, :get, "/x")
    end

    test "returns headers keyed by downcased name, with values as a list" do
      expect_request(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-range", "0-1/2")
        |> Req.Test.json(%{})
      end)

      assert {:ok, %{headers: headers}} = Client.request(AshSupabase.Test.Client, :get, "/x")
      assert headers["content-range"] == ["0-1/2"]
      # Callers such as `AshSupabase.PostgREST.parse_count/1` rely on this shape.
      assert is_map(headers)
    end

    test "does not raise when a JSON content type carries an unparseable body" do
      expect_request(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "not json at all")
      end)

      assert {:ok, %{body: "not json at all"}} =
               Client.request(AshSupabase.Test.Client, :get, "/x")
    end
  end

  describe "request!/4" do
    test "raises the error instead of returning it" do
      expect_request(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{"message" => "not found"}))
      end)

      assert_raise Error.Request, fn ->
        Client.request!(AshSupabase.Test.Client, :get, "/x")
      end
    end
  end
end
