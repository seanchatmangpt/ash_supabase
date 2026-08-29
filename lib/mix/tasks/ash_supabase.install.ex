if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshSupabase.Install do
    @shortdoc "Installs AshSupabase into a project"

    @moduledoc """
    #{@shortdoc}.

        mix igniter.install ash_supabase

    Wires up the formatter for `AshSupabase`'s DSL and scaffolds the one
    resource every app on this stack needs exactly one of: the shared
    `AshEvents` event log (plus its `clear_records_for_replay`
    implementation).

    ## Options

      * `--example` -- also scaffold a fully wired example resource (a
        `Todo`, mirroring this library's own test suite) showing the
        complete pattern: `AshSupabase.Resource` + `AshEvents.Events` +
        `Ash.Policy.Authorizer` on top of `AshPostgres.DataLayer`.

    ## After running this

    1. Add the generated `Events.Event` (and, with `--example`, `Todo`)
       module(s) to an `Ash.Domain`'s `resources do ... end` block --
       igniter doesn't guess which domain they belong in.
    2. Point `event_log MyApp.Events.Event` at the generated module from
       the `events do ... end` block of any resource you add
       `AshSupabase.Resource` + `AshEvents.Events` to.
    3. Run `mix ash_postgres.generate_migrations && mix ash_postgres.migrate`,
       then `mix ash_supabase.gen_policies && mix ash_postgres.migrate`
       again to lock PostgREST out of writing to those tables directly.
    4. Wire `AshSupabase.Auth.verify/3` into your auth pipeline so a
       verified Supabase JWT becomes the Ash `actor:` your resources'
       `policies` blocks authorize against.
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _source) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        example: "mix igniter.install ash_supabase",
        schema: [example: :boolean],
        defaults: [example: false]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      event_log = Igniter.Project.Module.module_name(igniter, "Events.Event")
      clear_records = Igniter.Project.Module.module_name(igniter, "Events.ClearRecords")
      repo = Igniter.Project.Module.module_name(igniter, "Repo")

      igniter
      |> Igniter.Project.Formatter.import_dep(:ash_supabase)
      |> Igniter.Project.Formatter.import_dep(:ash_events)
      |> Igniter.Project.Formatter.import_dep(:ash_postgres)
      |> create_clear_records(clear_records)
      |> create_event_log(event_log, clear_records, repo)
      |> maybe_create_example(igniter.args.options[:example], event_log, repo)
      |> Igniter.add_notice("""
      AshSupabase installed. Two things it could not safely guess for you:

        1. #{inspect(event_log)} (and its resources() entry) needs adding
           to one of your `Ash.Domain`s -- `resources do resource #{inspect(event_log)} end`.
        2. After your first `mix ash_postgres.migrate`, run
           `mix ash_supabase.gen_policies && mix ash_postgres.migrate`
           to lock PostgREST's `anon`/`authenticated` roles out of every
           AshSupabase-managed table.

      See the AshSupabase moduledoc (`h AshSupabase`) for the full picture.
      """)
    end

    defp create_clear_records(igniter, clear_records) do
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, clear_records)

      if exists? do
        igniter
      else
        Igniter.Project.Module.create_module(igniter, clear_records, """
        @moduledoc \"\"\"
        Clears every AshSupabase-managed table before AshEvents replays the
        event log, so replay rebuilds state from nothing instead of
        double-applying on top of what's already there.
        \"\"\"

        use AshEvents.ClearRecordsForReplay

        @impl true
        def clear_records!(_opts) do
          Application.get_env(:#{Mix.Project.config()[:app]}, :ash_domains, [])
          |> Enum.flat_map(&Ash.Domain.Info.resources/1)
          |> Enum.uniq()
          |> Enum.filter(&(AshSupabase.Resource in Spark.extensions(&1)))
          |> Enum.each(&Ash.bulk_destroy!(&1, :destroy, %{}, authorize?: false, strategy: [:atomic, :stream]))

          :ok
        end
        """)
      end
    end

    defp create_event_log(igniter, event_log, clear_records, repo) do
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, event_log)

      if exists? do
        igniter
      else
        Igniter.Project.Module.create_module(igniter, event_log, """
        @moduledoc \"\"\"
        The shared AshEvents event log -- the append-only half of every
        AshSupabase.Resource's dual-table pattern. Point every resource's
        `events do event_log #{inspect(event_log)} end` at this module.
        \"\"\"

        use Ash.Resource,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshEvents.EventLog]

        postgres do
          table "events"
          repo #{inspect(repo)}
        end

        event_log do
          clear_records_for_replay #{inspect(clear_records)}
          public_fields :all
        end

        actions do
          read :read do
            primary? true
            pagination keyset?: true
          end
        end
        """)
      end
    end

    defp maybe_create_example(igniter, false, _event_log, _repo), do: igniter

    defp maybe_create_example(igniter, true, event_log, repo) do
      todo = Igniter.Project.Module.module_name(igniter, "Todos.Todo")
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, todo)

      if exists? do
        igniter
      else
        Igniter.Project.Module.create_module(igniter, todo, """
        @moduledoc \"\"\"
        Example AshSupabase resource: every write goes through Ash, every
        write produces an event (#{inspect(event_log)}), and PostgREST is
        never granted direct access -- see `mix ash_supabase.gen_policies`.
        \"\"\"

        use Ash.Resource,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshSupabase.Resource, AshEvents.Events],
          authorizers: [Ash.Policy.Authorizer]

        postgres do
          table "todos"
          repo #{inspect(repo)}
        end

        supabase do
          realtime? true
        end

        events do
          event_log #{inspect(event_log)}
        end

        attributes do
          uuid_primary_key :id
          attribute :title, :string, allow_nil?: false, public?: true
          attribute :completed, :boolean, default: false, public?: true
          attribute :user_id, :uuid, allow_nil?: false, public?: true
          create_timestamp :inserted_at
          update_timestamp :updated_at
        end

        actions do
          defaults [:read, :destroy]

          create :create do
            accept [:title, :user_id]
          end

          update :update do
            accept [:title, :completed]
          end
        end

        policies do
          policy always() do
            authorize_if actor_present()
          end

          policy action_type(:create) do
            authorize_if expr(^actor(:id) == user_id)
          end

          policy action_type([:read, :update, :destroy]) do
            authorize_if expr(user_id == ^actor(:id))
          end
        end
        """)
      end
    end
  end
else
  defmodule Mix.Tasks.AshSupabase.Install do
    @moduledoc "Installs AshSupabase into a project. Should be called with `mix igniter.install ash_supabase`"

    @shortdoc @moduledoc

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_supabase.install' requires igniter to be run.

      Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
