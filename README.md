# AshSupabase

Route every Supabase CRUD operation through [Ash](https://ash-hq.org), with
a **dual-table event-sourcing** data layer: every write produces both a
row in your table and an immutable event, in one transaction, and Postgres
itself -- not application convention -- refuses any write that didn't come
through Ash.

## Why

Supabase is Postgres plus three services layered directly on top of it:

- **PostgREST** -- a REST API generated straight from your schema.
- **Realtime** -- a logical-replication feed clients can subscribe to.
- **GoTrue (Auth)** -- a Postgres-backed user table plus JWT issuance.

None of those services care *how* a row got written; they just read the
database. The default Supabase pattern lets PostgREST write directly,
authorized by hand-maintained Row Level Security policies. That works, but
it means your authorization logic, your audit trail, and your business
rules all have to be re-derived in SQL -- and there's no single place that
knows "this happened."

AshSupabase inverts that: PostgREST is locked out of writing at the
database level, and every write instead flows through an `Ash.Resource`.
You get Ash's actions, changes, and `Ash.Policy.Authorizer` policies as
your one authorization system, and -- because every resource is required
to pair with an [`AshEvents`](https://hexdocs.pm/ash_events) event log --
a complete, replayable history of everything that ever happened, for free.

## The dual-table pattern

```
                       one Ash action (create/update/destroy)
                                     │
                                     ▼
                     ┌────────────────────────────┐
                     │   one Postgres transaction   │
                     └───────────────┬────────────┘
                                     │
                  ┌──────────────────┴──────────────────┐
                  ▼                                      ▼
     ┌────────────────────────┐            ┌────────────────────────┐
     │   live projection table  │            │      event log table    │
     │   (AshPostgres.DataLayer)│            │     (AshEvents.EventLog) │
     │                         │            │                          │
     │  what PostgREST/Realtime│            │  append-only, replayable │
     │  clients actually read  │            │  audit trail; rebuilds   │
     │                         │            │  the left table alone    │
     └────────────────────────┘            └────────────────────────┘
                  │
                  ▼
        RLS: `anon`/`authenticated` REVOKEd
        (see `mix ash_supabase.gen_policies`)
        -- direct PostgREST writes refused
        by Postgres itself, not by convention
```

`AshSupabase.Resource` enforces this at **compile time**: a resource
cannot declare itself Supabase-fronted without also carrying
`AshEvents.Events` and a configured `event_log`. There is no code path
that produces a row in your table without also producing an event.

## Installation

```elixir
def deps do
  [
    {:ash_supabase, "~> 0.1"}
  ]
end
```

Then, in an app with `ash` + `ash_postgres` already installed:

```
mix igniter.install ash_supabase
```

This scaffolds the one resource every app on this stack needs exactly one
of -- the shared `AshEvents` event log -- and wires the formatter. See
`mix help ash_supabase.install` for the full "what to do next" list (short
version: add the generated event log to an `Ash.Domain`, then follow the
Quick start below).

## Quick start

An event log every `AshSupabase.Resource` in your app points at:

```elixir
defmodule MyApp.Events.Event do
  use Ash.Resource,
    domain: MyApp.Events,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.EventLog]

  postgres do
    table "events"
    repo MyApp.Repo
  end

  event_log do
    clear_records_for_replay MyApp.Events.ClearRecords
    persist_actor_primary_key :user_id, MyApp.Accounts.User
  end

  actions do
    read :read do
      primary? true
      # AshEvents streams this action during replay -- it needs pagination.
      pagination keyset?: true
    end
  end
end
```

```elixir
defmodule MyApp.Events.ClearRecords do
  use AshEvents.ClearRecordsForReplay

  @impl true
  def clear_records!(_opts) do
    :my_app
    |> AshSupabase.Info.supabase_resources()
    |> Enum.each(&Ash.bulk_destroy!(&1, :destroy, %{}, authorize?: false))

    :ok
  end
end
```

And a resource that's actually fronted by Supabase:

```elixir
defmodule MyApp.Todos.Todo do
  use Ash.Resource,
    domain: MyApp.Todos,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshSupabase.Resource, AshEvents.Events],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "todos"
    repo MyApp.Repo
  end

  supabase do
    realtime? true            # keep Supabase Realtime clients live (default)
    expose_via_postgrest? false  # no direct PostgREST access at all (default)
  end

  events do
    event_log MyApp.Events.Event
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
    create :create, accept: [:title, :user_id]
    update :update, accept: [:title, :completed]
  end

  policies do
    policy always(), do: authorize_if(actor_present())
    policy action_type(:create), do: authorize_if(expr(^actor(:id) == user_id))
    policy action_type([:read, :update, :destroy]), do: authorize_if(expr(user_id == ^actor(:id)))
  end
end
```

Then, as usual for any Ash + AshPostgres resource:

```
mix ash_postgres.generate_migrations
mix ash_postgres.migrate
```

...and once you've migrated the tables into existence, lock PostgREST out
of them:

```
mix ash_supabase.gen_policies
mix ash_postgres.migrate
```

From this point on, `Ash.create!(MyApp.Todos.Todo, ...)` writes both the
`todos` row and the matching `events` row, atomically, and Supabase's
`anon`/`authenticated` Postgres roles cannot write to `todos` at all.

## `supabase do ... end`

| Option | Default | Meaning |
| --- | --- | --- |
| `realtime?` | `true` | Add this table to the `supabase_realtime` publication. |
| `expose_via_postgrest?` | `false` | Grant the `anon` role (and, with `rls_authenticated_select?`, `authenticated`) a read-only RLS policy. Writes are **never** generated regardless of this flag. |
| `postgrest_read_only?` | `true` | Documents that a direct-PostgREST grant, when enabled, is read-only. Writes always go through Ash. |
| `rls_authenticated_select?` | `false` | Also grant `authenticated` (not just `anon`) the read-only policy. |

## `mix ash_supabase.gen_policies`

Introspects every domain configured under `config :my_app, ash_domains:
[...]` and writes one idempotent Ecto migration per repo containing:

- `ENABLE ROW LEVEL SECURITY` + `REVOKE ALL ... FROM anon, authenticated`
  for every `AshSupabase.Resource` table -- the default-deny baseline.
- A `SELECT`-only RLS policy for resources with `expose_via_postgrest?
  true`.
- `ALTER PUBLICATION supabase_realtime ADD TABLE ...` for resources with
  `realtime? true`.
- Full lockdown, unconditionally, for every `AshEvents` event log -- the
  audit trail is never meant to be client-readable.

Run it after `mix ash_postgres.generate_migrations`, and again any time
you add, remove, or reconfigure an `AshSupabase.Resource`. Pass
`--dry-run` to print the SQL instead of writing a migration.

## Auth: turning a Supabase JWT into an Ash actor

`AshSupabase.Auth.verify/3` verifies a Supabase-issued JWT (the legacy
shared-secret / HS256 model, with no third-party JWT dependency) and
returns an `AshSupabase.Auth.Actor{id, role, email, claims}` you pass
straight as the `actor:` option:

```elixir
def call(conn, _opts) do
  with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
       {:ok, actor} <- AshSupabase.Auth.verify(token, jwt_secret()) do
    Ash.PlugHelpers.set_actor(conn, actor)
  else
    _ -> Ash.PlugHelpers.set_actor(conn, nil)
  end
end
```

`actor(:id)` / `actor(:role)` inside a resource's `policies` block then
refer to `actor.id` / `actor.role` exactly as in the `Todo` example above.
Projects using Supabase's newer asymmetric (JWKS) signing keys should
implement the `AshSupabase.Auth` behaviour against a JWKS client and pass
it as `verifier:`.

## Event replay

Every `AshSupabase.Resource` write is replayable, because it's really
just `AshEvents` underneath:

```elixir
MyApp.Events.Event
|> Ash.ActionInput.for_action(:replay, %{})
|> Ash.run_action!()
```

Replay clears every `AshSupabase.Resource` table (via your
`clear_records_for_replay` implementation) and reapplies every event in
order -- useful for rebuilding a projection after a bug fix, backfilling
a new resource, or point-in-time debugging (`point_in_time:`/
`last_event_id:` arguments; see the
[AshEvents docs](https://hexdocs.pm/ash_events)).

## Developing this library

```
mix deps.get
createuser ash_supabase --superuser   # or however you provision a role locally
createdb ash_supabase_test -O ash_supabase
mix ash_postgres.migrate
mix test
```

The test suite (`test/support`) is itself a complete worked example --
`Accounts.User`, `Events.Event`, `Todos.Todo` -- exercised against a real
Postgres database, including RLS/Realtime grants (`test/sql_test.exs`),
compile-time DSL enforcement (`test/resource_verifiers_test.exs`), the
dual-table CRUD/replay flow (`test/dual_table_test.exs`), and JWT
verification (`test/auth_test.exs`).

## License

MIT, see [LICENSE](LICENSE).
