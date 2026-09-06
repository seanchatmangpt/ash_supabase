if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshSupabase.Install do
    @example "mix igniter.install ash_supabase"

    @shortdoc "Installs AshSupabase into an existing project."
    @moduledoc """
    #{@shortdoc}

    Wires a project up to a Supabase project by doing the four things every
    installation needs, and nothing else:

      * generates a client module (`MyApp.Supabase` by default) that
        `use`s `AshSupabase.Client`,
      * adds a `config/runtime.exs` block reading `SUPABASE_URL`,
        `SUPABASE_ANON_KEY` and `SUPABASE_JWT_SECRET` from the environment, so
        that credentials are never committed,
      * imports `:ash_supabase` into `.formatter.exs` so the `supabase` DSL
        section formats without parentheses,
      * teaches `Spark.Formatter` where the `supabase` section belongs in a
        resource.

    Every step is idempotent: running the installer again on an already
    installed project makes no changes, so it is safe to re-run after upgrading.

    ## Example

    ```sh
    #{@example}
    ```

    Or, if `ash_supabase` is already a dependency:

    ```sh
    mix ash_supabase.install
    ```

    ## Options

      * `--client` (`-c`) - the client module to generate. Defaults to
        `<YourApp>.Supabase`.
      * `--yes` (`-y`) - accept all prompts.
    """

    use Igniter.Mix.Task

    @doc false
    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        example: @example,
        schema: [
          client: :string,
          yes: :boolean
        ],
        aliases: [
          c: :client,
          y: :yes
        ]
      }
    end

    @doc false
    @impl Igniter.Mix.Task
    def igniter(igniter) do
      otp_app = Igniter.Project.Application.app_name(igniter)
      client = client_module(igniter)

      igniter
      |> Igniter.Project.Formatter.import_dep(:ash_supabase)
      |> Spark.Igniter.prepend_to_section_order(:"Ash.Resource", [:supabase])
      |> create_client_module(client, otp_app)
      |> configure_runtime(otp_app, client)
      |> add_next_steps(client)
    end

    defp client_module(igniter) do
      case igniter.args.options[:client] do
        nil -> Igniter.Project.Module.module_name(igniter, "Supabase")
        client -> Igniter.Project.Module.parse(client)
      end
    end

    # `find_and_update_or_create_module/4` with a no-op updater is what makes
    # this idempotent: an existing client module is left exactly as the user
    # wrote it, rather than being regenerated or duplicated.
    defp create_client_module(igniter, client, otp_app) do
      contents = """
      @moduledoc "The Supabase project used by #{inspect(otp_app)}. Configured in `config/runtime.exs`."

      use AshSupabase.Client, otp_app: #{inspect(otp_app)}
      """

      Igniter.Project.Module.find_and_update_or_create_module(
        igniter,
        client,
        contents,
        fn zipper -> {:ok, zipper} end
      )
    end

    # Written at the top level of `runtime.exs` rather than inside a
    # `config_env() == :prod` block, because the same three variables drive dev
    # and CI against a local `supabase start` stack.
    defp configure_runtime(igniter, otp_app, client) do
      Enum.reduce(runtime_settings(), igniter, fn {key, env_var}, igniter ->
        Igniter.Project.Config.configure_new(
          igniter,
          "runtime.exs",
          otp_app,
          [client, key],
          {:code, get_env(env_var)}
        )
      end)
    end

    @doc false
    @spec runtime_settings() :: [{atom(), String.t()}]
    def runtime_settings do
      [
        url: "SUPABASE_URL",
        api_key: "SUPABASE_ANON_KEY",
        jwt_secret: "SUPABASE_JWT_SECRET"
      ]
    end

    defp get_env(variable), do: Sourceror.parse_string!(~s|System.get_env("#{variable}")|)

    defp add_next_steps(igniter, client) do
      Igniter.add_notice(igniter, """
      AshSupabase installed.

      Next steps:

      1. Export your project's credentials, from Project Settings -> API in the
         Supabase dashboard:

             export SUPABASE_URL="https://<project-ref>.supabase.co"
             export SUPABASE_ANON_KEY="<publishable/anon key>"
             export SUPABASE_JWT_SECRET="<jwt secret, only for legacy HS256 tokens>"

         For production, consider `System.fetch_env!/1` in `config/runtime.exs`
         so a missing variable fails the boot loudly instead of at the first
         request.

      2. Generate a resource backed by the Supabase Data API:

             mix ash_supabase.gen.resource #{example_resource(client)} \\
               --table posts --attrs title:string,body:string

      3. Expose the table through the Data API. PostgREST only sees tables in a
         schema listed under Project Settings -> API -> Exposed schemas, and Row
         Level Security applies to every request made with the anon key.

      #{inspect(client)} is ready to use directly too:

          AshSupabase.Client.request(#{inspect(client)}, :get, "/rest/v1/posts", params: [select: "*"])
      """)
    end

    defp example_resource(client) do
      case client |> Module.split() |> Enum.drop(-1) do
        [] -> "MyApp.Blog.Post"
        prefix -> Enum.join(prefix ++ ["Blog", "Post"], ".")
      end
    end
  end
else
  defmodule Mix.Tasks.AshSupabase.Install do
    @shortdoc "Installs AshSupabase | Install `igniter` to use"
    @moduledoc @shortdoc

    use Mix.Task

    @doc false
    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_supabase.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
