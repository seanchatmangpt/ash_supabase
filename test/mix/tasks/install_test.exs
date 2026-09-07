defmodule Mix.Tasks.AshSupabase.InstallTest do
  @moduledoc """
  Covers both Igniter tasks: the installer and the resource generator.

  These run against `Igniter.Test.test_project/1`, an in-memory mix project, so
  nothing is written to disk. The assertions that matter most here are the
  idempotency ones: an installer that is not safe to re-run duplicates config
  the second time someone runs `mix igniter.install ash_supabase`.
  """
  use ExUnit.Case, async: true

  import Igniter.Test

  # `apply_igniter!/1` evaluates the project's generated config, so running the
  # installer writes its `config :spark, formatter: ...` (and the generated
  # client's runtime config) into the REAL application environment of the test
  # run. Left in place, that makes `Spark.Formatter` reorder sections in files
  # formatted by later tests, and the idempotency assertions fail depending on
  # the order ExUnit happens to pick. Snapshot and restore around every test.
  setup do
    snapshots = Enum.map([:spark, :test], &{&1, Application.get_all_env(&1)})

    on_exit(fn ->
      Enum.each(snapshots, fn {app, env} ->
        for {key, _} <- Application.get_all_env(app), do: Application.delete_env(app, key)
        for {key, value} <- env, do: Application.put_env(app, key, value)
      end)
    end)

    :ok
  end

  doctest Mix.Tasks.AshSupabase.Gen.Resource

  describe "mix ash_supabase.install" do
    test "generates a client module for the app" do
      test_project()
      |> Igniter.compose_task("ash_supabase.install", ["--yes"])
      |> assert_creates("lib/test/supabase.ex", """
      defmodule Test.Supabase do
        @moduledoc "The Supabase project used by :test. Configured in `config/runtime.exs`."

        use AshSupabase.Client, otp_app: :test
      end
      """)
    end

    test "honors --client" do
      test_project()
      |> Igniter.compose_task("ash_supabase.install", ["--client", "Test.Analytics.Project", "-y"])
      |> assert_creates("lib/test/analytics/project.ex", fn contents ->
        assert contents =~ "defmodule Test.Analytics.Project do"
        assert contents =~ "use AshSupabase.Client, otp_app: :test"
      end)
      |> refute_creates("lib/test/supabase.ex")
    end

    test "reads credentials from the environment in runtime.exs" do
      test_project()
      |> Igniter.compose_task("ash_supabase.install", ["--yes"])
      |> assert_creates("config/runtime.exs", """
      import Config

      config :test, Test.Supabase,
        url: System.get_env("SUPABASE_URL"),
        api_key: System.get_env("SUPABASE_ANON_KEY"),
        jwt_secret: System.get_env("SUPABASE_JWT_SECRET")
      """)
    end

    test "imports :ash_supabase into .formatter.exs" do
      test_project()
      |> Igniter.compose_task("ash_supabase.install", ["--yes"])
      |> assert_has_patch(".formatter.exs", """
      + |  import_deps: [:ash_supabase]
      """)
    end

    test "teaches the spark formatter where the supabase section goes" do
      test_project()
      |> Igniter.compose_task("ash_supabase.install", ["--yes"])
      |> assert_creates("config/config.exs", fn contents ->
        assert contents =~
                 ~s|config :spark, formatter: ["Ash.Resource": [section_order: [:supabase]]]|
      end)
    end

    test "prints next steps" do
      test_project()
      |> Igniter.compose_task("ash_supabase.install", ["--yes"])
      |> assert_has_notice(fn notice ->
        String.contains?(notice, "SUPABASE_ANON_KEY") and
          String.contains?(notice, "mix ash_supabase.gen.resource")
      end)
    end

    test "is idempotent" do
      test_project()
      |> Igniter.compose_task("ash_supabase.install", ["--yes"])
      |> apply_igniter!()
      |> Igniter.compose_task("ash_supabase.install", ["--yes"])
      |> assert_unchanged()
    end

    test "leaves a hand-written client module alone" do
      client = """
      defmodule Test.Supabase do
        use AshSupabase.Client

        @impl true
        def config, do: [url: "http://localhost:54321", api_key: "anon"]
      end
      """

      test_project(files: %{"lib/test/supabase.ex" => client})
      |> Igniter.compose_task("ash_supabase.install", ["--yes"])
      |> assert_unchanged("lib/test/supabase.ex")
    end

    test "does not overwrite existing runtime configuration" do
      runtime = """
      import Config

      config :test, Test.Supabase,
        url: "http://localhost:54321",
        api_key: "anon"
      """

      test_project(files: %{"config/runtime.exs" => runtime})
      |> Igniter.compose_task("ash_supabase.install", ["--yes"])
      |> assert_has_patch("config/runtime.exs", """
      + |  jwt_secret: System.get_env("SUPABASE_JWT_SECRET")
      """)
      |> apply_igniter!()
      |> then(fn igniter ->
        contents = Rewrite.Source.get(igniter.rewrite.sources["config/runtime.exs"], :content)

        assert contents =~ ~s|url: "http://localhost:54321"|
        assert contents =~ ~s|api_key: "anon"|
        refute contents =~ "SUPABASE_URL"
      end)
    end
  end

  describe "mix ash_supabase.gen.resource" do
    test "generates a resource using the Supabase data layer" do
      test_project()
      |> Igniter.compose_task("ash_supabase.gen.resource", [
        "Test.Blog.Post",
        "--table",
        "posts",
        "--attrs",
        "title:string:required,body:string",
        "--yes"
      ])
      |> assert_creates("lib/test/blog/post.ex", """
      defmodule Test.Blog.Post do
        use Ash.Resource,
          otp_app: :test,
          domain: Test.Blog,
          data_layer: AshSupabase.DataLayer

        supabase do
          table("posts")
          client(Test.Supabase)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        attributes do
          uuid_primary_key(:id)

          attribute :title, :string do
            allow_nil?(false)
            public?(true)
          end

          attribute :body, :string do
            public?(true)
          end
        end
      end
      """)
    end

    test "adds the resource to its domain" do
      test_project()
      |> Igniter.compose_task("ash_supabase.gen.resource", ["Test.Blog.Post", "--yes"])
      |> assert_creates("lib/test/blog.ex", fn contents ->
        assert contents =~ "use Ash.Domain"
        assert contents =~ "resource(Test.Blog.Post)"
      end)
      |> assert_creates("config/config.exs", fn contents ->
        assert contents =~ "config :test, ash_domains: [Test.Blog]"
      end)
    end

    test "infers the table name from the resource module" do
      test_project()
      |> Igniter.compose_task("ash_supabase.gen.resource", ["Test.Blog.Category", "--yes"])
      |> assert_creates("lib/test/blog/category.ex", fn contents ->
        assert contents =~ ~s|table("categories")|
      end)
    end

    test "honors --client and --schema" do
      test_project()
      |> Igniter.compose_task("ash_supabase.gen.resource", [
        "Test.Billing.Invoice",
        "--client",
        "Test.Analytics.Project",
        "--schema",
        "billing",
        "--yes"
      ])
      |> assert_creates("lib/test/billing/invoice.ex", fn contents ->
        assert contents =~ ~s|client(Test.Analytics.Project)|
        assert contents =~ ~s|schema("billing")|
      end)
    end

    test "an attribute marked primary_key replaces the generated uuid key" do
      test_project()
      |> Igniter.compose_task("ash_supabase.gen.resource", [
        "Test.Blog.Tag",
        "--attrs",
        "slug:string:primary_key,label:string:private",
        "--yes"
      ])
      |> assert_creates("lib/test/blog/tag.ex", fn contents ->
        refute contents =~ "uuid_primary_key"
        assert contents =~ "primary_key?(true)"
        assert contents =~ "allow_nil?(false)"
        assert contents =~ "public?(false)"
      end)
    end

    test "--timestamps adds inserted_at and updated_at" do
      test_project()
      |> Igniter.compose_task("ash_supabase.gen.resource", [
        "Test.Blog.Comment",
        "--timestamps",
        "--yes"
      ])
      |> assert_creates("lib/test/blog/comment.ex", fn contents ->
        assert contents =~ "timestamps()"
      end)
    end

    test "generates a placeholder when no attributes are given and no primary key is wanted" do
      test_project()
      |> Igniter.compose_task("ash_supabase.gen.resource", [
        "Test.Blog.Snapshot",
        "--primary-key",
        "none",
        "--yes"
      ])
      |> assert_creates("lib/test/blog/snapshot.ex", fn contents ->
        refute contents =~ "uuid_primary_key"

        assert contents =~
                 "# Add attributes with `mix ash_supabase.gen.resource --attrs name:type`"
      end)
    end

    test "is idempotent" do
      argv = ["Test.Blog.Post", "--table", "posts", "--attrs", "title:string", "--yes"]

      test_project()
      |> Igniter.compose_task("ash_supabase.gen.resource", argv)
      |> apply_igniter!()
      |> Igniter.compose_task("ash_supabase.gen.resource", argv)
      |> assert_unchanged()
    end

    test "rejects an unknown attribute modifier" do
      assert_raise ArgumentError, ~r/Unknown attribute modifier "requried"/, fn ->
        Mix.Tasks.AshSupabase.Gen.Resource.parse_attr("title:string:requried")
      end
    end

    test "rejects an attribute without a type" do
      assert_raise ArgumentError, ~r/Invalid attribute "title"/, fn ->
        Mix.Tasks.AshSupabase.Gen.Resource.parse_attr("title")
      end
    end

    test "default_table pluralizes naively" do
      assert Mix.Tasks.AshSupabase.Gen.Resource.default_table(MyApp.Blog.Post) == "posts"
      assert Mix.Tasks.AshSupabase.Gen.Resource.default_table(MyApp.Blog.Entry) == "entries"
      assert Mix.Tasks.AshSupabase.Gen.Resource.default_table(MyApp.Blog.Status) == "statuses"
      assert Mix.Tasks.AshSupabase.Gen.Resource.default_table(MyApp.Blog.Match) == "matches"

      assert Mix.Tasks.AshSupabase.Gen.Resource.default_table(MyApp.Auth.UserToken) ==
               "user_tokens"
    end
  end
end
