defmodule AshSupabase.DataLayerTest do
  use AshSupabase.Case, async: true

  alias AshSupabase.Test.Blog.Post
  alias AshSupabase.Test.Blog.Tenanted
  alias AshSupabase.Test.Blog.UpsertPost

  require Ash.Query

  @id "550e8400-e29b-41d4-a716-446655440000"

  defp post_json(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => @id,
        "title" => "Hello",
        "body" => "World",
        "views" => 3,
        "is_published" => true,
        "status" => "published",
        "tags" => ["a", "b"],
        "metadata" => %{"k" => "v"},
        "inserted_at" => "2024-01-31T13:45:00Z"
      },
      overrides
    )
  end

  describe "reads" do
    test "issues a GET to the configured table with the project's REST prefix" do
      capture = expect_request(&Req.Test.json(&1, [post_json()]))

      assert {:ok, [post]} = Ash.read(Post)

      conn = capture.()
      assert conn.method == "GET"
      assert conn.request_path == "/rest/v1/posts"
      assert post.id == @id
      assert post.title == "Hello"
    end

    test "casts every column through its Ash type" do
      capture = expect_request(&Req.Test.json(&1, [post_json()]))

      assert {:ok, [post]} = Ash.read(Post)
      capture.()

      assert post.views == 3
      assert post.published? == true
      assert post.status == :published
      assert post.tags == ["a", "b"]
      assert post.metadata == %{"k" => "v"}
      assert post.inserted_at == ~U[2024-01-31 13:45:00.000000Z]
    end

    test "marks records as loaded so Ash treats them as persisted" do
      capture = expect_request(&Req.Test.json(&1, [post_json()]))

      assert {:ok, [post]} = Ash.read(Post)
      capture.()

      assert post.__meta__.state == :loaded
    end

    test "pushes filters down as query parameters" do
      capture = expect_request(&Req.Test.json(&1, []))

      Post
      |> Ash.Query.filter(title == "Hello" and views > 2)
      |> Ash.read!()

      params = query_params(capture.())
      assert {"title", "eq.Hello"} in params
      assert {"views", "gt.2"} in params
    end

    test "pushes sort down, mapping direction and null placement" do
      capture = expect_request(&Req.Test.json(&1, []))

      Post
      |> Ash.Query.sort(views: :desc, title: :asc_nils_last)
      |> Ash.read!()

      assert {"order", "views.desc,title.asc.nullslast"} in query_params(capture.())
    end

    test "pushes limit and offset down" do
      capture = expect_request(&Req.Test.json(&1, []))

      Post
      |> Ash.Query.limit(5)
      |> Ash.Query.offset(10)
      |> Ash.read!()

      params = query_params(capture.())
      assert {"limit", "5"} in params
      assert {"offset", "10"} in params
    end

    test "always selects the primary key, so records stay addressable" do
      capture = expect_request(&Req.Test.json(&1, []))

      Post
      |> Ash.Query.select([:title])
      |> Ash.read!()

      assert {"select", select} = List.keyfind(query_params(capture.()), "select", 0)
      columns = String.split(select, ",")
      assert "id" in columns
      assert "title" in columns
    end

    test "sends the anon key as both apikey and bearer token by default" do
      capture = expect_request(&Req.Test.json(&1, []))

      Ash.read!(Post)

      conn = capture.()
      assert header(conn, "apikey") == "test-anon-key"
      assert header(conn, "authorization") == "Bearer test-anon-key"
    end

    test "with_token/2 swaps the bearer token so RLS sees the user" do
      capture = expect_request(&Req.Test.json(&1, []))

      Post
      |> AshSupabase.DataLayer.with_token("user-jwt")
      |> Ash.read!()

      conn = capture.()
      assert header(conn, "authorization") == "Bearer user-jwt"
      # The apikey still identifies the project to the API gateway.
      assert header(conn, "apikey") == "test-anon-key"
    end

    test "selects the schema with Accept-Profile on reads" do
      capture = expect_request(&Req.Test.json(&1, []))

      Ash.read!(Post)

      assert header(capture.(), "accept-profile") == "public"
    end
  end

  describe "creates" do
    test "POSTs the dumped attributes and returns the created record" do
      capture = expect_request(&Req.Test.json(&1, post_json()))

      assert {:ok, post} = Ash.create(Post, %{title: "Hello", body: "World"})

      conn = capture.()
      assert conn.method == "POST"
      assert conn.request_path == "/rest/v1/posts"
      assert %{"title" => "Hello", "body" => "World"} = request_body(conn)
      assert post.title == "Hello"
    end

    test "asks for the created row back, since PostgREST returns nothing by default" do
      capture = expect_request(&Req.Test.json(&1, post_json()))

      Ash.create!(Post, %{title: "Hello"})

      assert header(capture.(), "prefer") =~ "return=representation"
    end

    test "asks for a single object rather than a one-element array" do
      capture = expect_request(&Req.Test.json(&1, post_json()))

      Ash.create!(Post, %{title: "Hello"})

      assert header(capture.(), "accept") == "application/vnd.pgrst.object+json"
    end

    test "dumps values into their JSON representation" do
      capture = expect_request(&Req.Test.json(&1, post_json()))

      Ash.create!(Post, %{title: "Hello", status: :published, tags: ["x"], published?: true})

      body = request_body(capture.())
      assert body["status"] == "published"
      assert body["tags"] == ["x"]
      # The attribute is `published?` but the column is `is_published`.
      assert body["is_published"] == true
      refute Map.has_key?(body, "published?")
    end

    test "uses Content-Profile, not Accept-Profile, on writes" do
      capture = expect_request(&Req.Test.json(&1, post_json()))

      Ash.create!(Post, %{title: "Hello"})

      conn = capture.()
      assert header(conn, "content-profile") == "public"
      assert header(conn, "accept-profile") == nil
    end
  end

  describe "upserts" do
    test "sends the merge-duplicates resolution and the conflict target" do
      capture = expect_request(&Req.Test.json(&1, post_json()))

      UpsertPost
      |> Ash.Changeset.for_create(:upsert_post, %{title: "Hello"})
      |> Ash.create!()

      conn = capture.()
      assert header(conn, "prefer") =~ "resolution=merge-duplicates"
      assert {"on_conflict", "title"} in query_params(conn)
    end
  end

  describe "updates" do
    test "PATCHes the row addressed by its primary key" do
      read = expect_request(&Req.Test.json(&1, [post_json()]))
      [post] = Ash.read!(Post)
      read.()

      capture = expect_request(&Req.Test.json(&1, post_json(%{"title" => "Changed"})))

      assert {:ok, updated} = Ash.update(post, %{title: "Changed"})

      conn = capture.()
      assert conn.method == "PATCH"
      assert {"id", "eq.#{@id}"} in query_params(conn)
      assert request_body(conn) == %{"title" => "Changed"}
      assert updated.title == "Changed"
    end
  end

  describe "destroys" do
    test "DELETEs the row addressed by its primary key" do
      read = expect_request(&Req.Test.json(&1, [post_json()]))
      [post] = Ash.read!(Post)
      read.()

      capture = expect_request(&Plug.Conn.send_resp(&1, 204, ""))

      assert :ok = Ash.destroy(post)

      conn = capture.()
      assert conn.method == "DELETE"
      assert {"id", "eq.#{@id}"} in query_params(conn)
    end
  end

  describe "counting" do
    test "uses a HEAD request and reads the total from Content-Range" do
      capture =
        expect_request(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-range", "0-24/3573")
          |> Plug.Conn.send_resp(200, "")
        end)

      assert {:ok, 3573} = Ash.count(Post)

      conn = capture.()
      assert conn.method == "HEAD"
      assert header(conn, "prefer") =~ "count=exact"
    end
  end

  describe "multitenancy" do
    test "context multitenancy selects a Postgres schema via the profile header" do
      capture = expect_request(&Req.Test.json(&1, []))

      Tenanted
      |> Ash.Query.set_tenant("tenant_a")
      |> Ash.read!()

      assert header(capture.(), "accept-profile") == "tenant_a"
    end

    # Writes carry their tenant on the changeset rather than on a query, so it
    # has to be read from there. Missing it writes to the wrong schema, which is
    # a cross-tenant data leak rather than an error.
    test "context multitenancy applies to creates" do
      capture = expect_request(&Req.Test.json(&1, %{"id" => @id, "name" => "x"}))

      Tenanted
      |> Ash.Changeset.for_create(:create, %{name: "x"}, tenant: "tenant_a")
      |> Ash.create!()

      assert header(capture.(), "content-profile") == "tenant_a"
    end

    test "context multitenancy applies to updates and destroys" do
      read = expect_request(&Req.Test.json(&1, [%{"id" => @id, "name" => "x"}]))

      [record] =
        Tenanted
        |> Ash.Query.set_tenant("tenant_a")
        |> Ash.read!()

      read.()

      capture = expect_request(&Req.Test.json(&1, %{"id" => @id, "name" => "y"}))
      Ash.update!(record, %{name: "y"}, tenant: "tenant_a")
      assert header(capture.(), "content-profile") == "tenant_a"

      capture = expect_request(&Plug.Conn.send_resp(&1, 204, ""))
      Ash.destroy!(record, tenant: "tenant_a")
      assert header(capture.(), "content-profile") == "tenant_a"
    end
  end

  describe "counting an impossible query" do
    test "does not issue a request for a filter that can never match" do
      Req.Test.stub(AshSupabase.Test.Client, fn _conn ->
        flunk("counting an impossible query should not reach the network")
      end)

      assert {:ok, 0} =
               Post
               |> Ash.Query.filter(title in [])
               |> Ash.count()
    end
  end

  describe "errors" do
    test "surfaces a PostgREST error with its code and message" do
      capture =
        expect_request(fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            409,
            Jason.encode!(%{
              "code" => "23505",
              "message" => "duplicate key value violates unique constraint \"posts_title_key\"",
              "details" => "Key (title)=(Hello) already exists.",
              "hint" => nil
            })
          )
        end)

      assert {:error, error} = Ash.create(Post, %{title: "Hello"})
      capture.()

      message = Exception.message(error)
      assert message =~ "23505"
      assert message =~ "duplicate key value"
    end

    test "a 406 from a single-object request surfaces rather than being swallowed" do
      capture =
        expect_request(fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            406,
            Jason.encode!(%{
              "code" => "PGRST116",
              "message" => "JSON object requested, multiple (or no) rows returned",
              "details" => "Results contain 0 rows",
              "hint" => nil
            })
          )
        end)

      assert {:error, error} = Ash.create(Post, %{title: "Hello"})
      capture.()

      assert Exception.message(error) =~ "PGRST116"
    end
  end

  describe "capabilities" do
    test "reports no transaction support, because PostgREST has none" do
      refute Ash.DataLayer.data_layer_can?(Post, :transact)
    end

    test "reports no relationship filtering" do
      refute Ash.DataLayer.data_layer_can?(Post, {:filter_relationship, :author})
    end

    test "reports no aggregates beyond count" do
      assert Ash.DataLayer.data_layer_can?(Post, {:query_aggregate, :count})
      refute Ash.DataLayer.data_layer_can?(Post, {:query_aggregate, :sum})
    end

    test "reports the filter expressions it can actually translate" do
      assert Ash.DataLayer.data_layer_can?(Post, {:filter_expr, %Ash.Query.Operator.Eq{}})
      refute Ash.DataLayer.data_layer_can?(Post, {:filter_expr, %Ash.Query.Function.Fragment{}})
    end
  end
end
