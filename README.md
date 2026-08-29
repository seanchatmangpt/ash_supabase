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
      # AshEvents streams this action during replay -- it needs pagination
      # *allowed*, but not required for ordinary reads.
      pagination keyset?: true, required?: false
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
    gateway_actions [:create, :update, :destroy]  # reachable via AshSupabase.Gateway
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

## Clients only ever see Supabase

Locking PostgREST's writes down (above) answers "how do we stop a client
writing around Ash." It says nothing about how a client is supposed to
write *at all* -- given it still only speaks the Supabase SDK it already
knows, with zero awareness that Ash or Elixir exist. That's what
`AshSupabase.Gateway` plus generated-client tooling
([`ggen_igniter`](https://hex.pm/packages/ggen_igniter)) are for.

```
                 ┌─────────────────────────────┐
  browser/mobile │  import { createTodo } from  │
  TypeScript code│  "./ash_supabase_client";     │
                 │  await createTodo(supabase,   │
                 │    { title, user_id });       │
                 └───────────────┬───────────────┘
                                 │  supabase.functions.invoke("ash-gateway", {...})
                                 ▼
                 ┌─────────────────────────────┐
                 │  supabase/functions/          │  <- the ONLY thing a client
                 │  ash-gateway/index.ts (Deno)  │     ever talks to directly
                 │  -- a static, generic proxy   │
                 └───────────────┬───────────────┘
                                 │  POST, forwarded verbatim (body + JWT)
                                 ▼
                 ┌─────────────────────────────┐
                 │      AshSupabase.Gateway      │  <- Ash policies/actions
                 │  {resource, action, params}   │     run here, same as any
                 │  -> Ash.Changeset.for_*/Ash.*  │     other Ash entry point
                 └─────────────────────────────┘
```

1. Opt a resource's actions in:

   ```elixir
   supabase do
     gateway_actions [:create, :update, :destroy]
   end
   ```

2. Mount `AshSupabase.Gateway` somewhere Ash can reach it (a Phoenix
   route, or standalone via Bandit):

   ```elixir
   # router.ex
   forward "/functions/v1/ash-gateway", to: AshSupabase.Gateway,
     init_opts: [otp_app: :my_app, jwt_secret: {MyApp.Secrets, :jwt_secret, []}]
   ```

3. Generate the typed TypeScript client from your live Ash resources:

   ```
   mix ash_supabase.gen_client
   ```

   This runs `mix ash_supabase.export_ontology` (introspects every
   `gateway_actions`-opted-in resource into an RDF ontology at
   `priv/ggen/ash-supabase-client-pack/ontology.ttl` -- attribute names
   and JSON-representable types only, no Ash/Elixir vocabulary) then
   `mix ggen_igniter.sync --pack ash-supabase-client-pack`, which
   deterministically projects that ontology into
   `priv/generated/ash_supabase_client.ts`: one typed function and
   params interface per gateway action, plus a return-type interface per
   resource, e.g. (this exact output, for the `Todo` example above):

   ```typescript
   export interface Todo {
     id: string;
     title: string;
     completed: boolean;
     user_id: string;
   }

   export interface CreateTodoParams {
     title: string;
     user_id: string;
   }

   export async function createTodo(
     supabase: SupabaseClient,
     params: CreateTodoParams,
   ): Promise<Todo> {
     return invokeAshGateway<Todo>(supabase, "todos", "create", params);
   }
   ```

   Re-run it whenever a gateway-exposed action's attributes/arguments
   change -- the generated file always reflects the live resource, never
   a hand-maintained copy that can drift.

4. Copy `priv/supabase/functions/ash-gateway/index.ts` into your own
   Supabase project's `supabase/functions/ash-gateway/index.ts` and
   deploy it (`supabase functions deploy ash-gateway`), pointing
   `ASH_GATEWAY_URL` at wherever you mounted `AshSupabase.Gateway`. It's
   resource-agnostic -- a static proxy, never regenerated.

From here, a frontend developer writes:

```typescript
import { createTodo } from "./ash_supabase_client";
const todo = await createTodo(supabase, { title: "Buy milk", user_id: me.id });
```

and never sees Ash, Elixir, Reactor, or a single backend-framework term --
`AshSupabase.Gateway` verifies the Supabase JWT
(`AshSupabase.Auth.verify/3`), builds the Ash actor, and runs the exact
same policy/action pipeline every other path into this library already
goes through (see `AshSupabase.Gateway`'s moduledoc for the full request/
response contract, including its `404`-not-`403` handling of a record the
actor can't read -- matching Ash's own "never confirm existence" security
convention).

## `supabase do ... end`

| Option | Default | Meaning |
| --- | --- | --- |
| `realtime?` | `true` | Add this table to the `supabase_realtime` publication. |
| `expose_via_postgrest?` | `false` | Grant the `anon` role (and, with `rls_authenticated_select?`, `authenticated`) a read-only RLS policy. Writes are **never** generated regardless of this flag. |
| `postgrest_read_only?` | `true` | Documents that a direct-PostgREST grant, when enabled, is read-only. Writes always go through Ash. |
| `rls_authenticated_select?` | `false` | Also grant `authenticated` (not just `anon`) the read-only policy. |
| `gateway_actions` | `[]` | Action names reachable through `AshSupabase.Gateway` and generated into the typed TypeScript client (see "Clients only ever see Supabase" above). Empty by default -- opt in explicitly, same as `expose_via_postgrest?`. |

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

## Atomic multi-action processes without `Ash.Reactor`'s fixed step graph

`Ash.Reactor`'s `transaction do ... end` block is the right tool when the
shape of a process is static (a fixed number of named steps -- see
`AshSupabase.Ledger.Transfer` below). When the shape is dynamic (a
variable-length list of postings, a variable-length candidate walk over a
federation graph), a plain function wrapping several Ash calls in one Ecto
transaction is the better fit -- but doing that with raw
`Repo.transaction/1` silently drops every Ash notification those calls
produce (Ash logs "Missed N notifications" and moves on). `AshSupabase.Transaction.run/2`
closes that gap, using Ash's own internal transaction-nesting contract, so
the same "notification only after commit" guarantee holds either way:

```elixir
AshSupabase.Transaction.run(MyApp.Repo, fn ->
  account
  |> Ash.Changeset.for_update(:post_debit, %{amount_cents: 100})
  |> Ash.update!()

  MyApp.Receipts.Receipt.create!(%{...})
end)
```

## Event/state replay equivalence

`AshSupabase.Replay` is the generic, resource-agnostic half of "does
replaying the event log alone reproduce the same live state": it hashes a
loaded record's public attributes deterministically (`state_hash/2`) and
compares two such hashes (`compare/2`). The "load, replay, reload"
sequencing is the caller's -- see any of `test/chicago_test_14_replay_test.exs`,
`test/chicago_test_17_deterministic_replay_test.exs`, or the crown scenario
below for the pattern.

## The ZOE LA Chicago proving ground

`test/support` and every `test/chicago_test_*.exs` file are a from-scratch
implementation of the [v26.8.29 PRD/ARD](https://ash-hq.org) doctrine this
library exists to serve: Supabase as transport/projection only, Ash as
sole authority, `Ash.Reactor` (or `AshSupabase.Transaction`, for
dynamic-shaped processes) for deterministic execution, zero LLM in any
production code path. It's a real church-operations domain -- identity,
a double-entry financial ledger, a generic obligation grammar (Welcome,
Infant Room, Escort/Coverage, Care, Recovery, Service-animal routing), and
Kids capacity + cross-church federation -- built and tested against real
Postgres, not mocked, per the doctrine's own "Chicago style" testing rule:
never assert a function was called, always assert the actual resulting
state.

| # | Scenario | Test file |
| --- | --- | --- |
| 1 | Unauthorized user delete | `test/dual_table_test.exs` |
| 2-4, 18-20 | Admin credit / unauthorized credit / unbalanced construction | `test/chicago_test_02_03_04_finance_test.exs` |
| 5 | Welcome before security | `test/chicago_test_05_welcome_test.exs` |
| 6 | Parent-with-infant routing | `test/chicago_test_06_infant_room_test.exs` |
| 7 | Escort without losing Welcome coverage | `test/chicago_test_07_escort_test.exs` |
| 8 | Service-animal routing | `test/chicago_test_08_service_animal_test.exs` |
| 9 | Kids capacity deficit | `test/chicago_test_09_kids_capacity_test.exs` |
| 10 | Federated Kids fulfillment | `test/chicago_test_10_kids_federation_test.exs` |
| 11 | Care handoff | `test/chicago_test_11_care_test.exs` |
| 12 | Recovery support routing | `test/chicago_test_12_recovery_test.exs` |
| 13 | Notification only after commit | `test/chicago_test_13_notification_after_commit_test.exs` |
| 14 | Event replay | `test/chicago_test_14_replay_test.exs` |
| 15 | Supabase outage doctrine | `test/chicago_test_15_supabase_outage_test.exs` |
| 16 | LLM blackout (standing release gate) | `test/chicago_test_16_llm_zero_test.exs` |
| 17 | Deterministic replay | `test/chicago_test_17_deterministic_replay_test.exs` |
| 46-47 | Crown scenario (Kids federation + Welcome + escort + a balanced credit, end to end) | `test/chicago_test_46_47_crown_test.exs` |

One deliberate, stated scope boundary: this proving ground does not
implement a dedicated "check a child in" resource -- the Kids capability
built here is capacity/staffing and its federated fulfillment, not
per-child check-in. The crown scenario says so explicitly rather than
implying more than what's actually there.

## Developing this library

```
mix deps.get
createuser ash_supabase --superuser   # or however you provision a role locally
createdb ash_supabase_test -O ash_supabase
mix ash_postgres.migrate
mix test
```

The test suite (`test/support`) is itself a complete worked example --
identity, receipts, the double-entry ledger, the generic obligation
grammar, and Kids capacity + federation -- exercised against a real
Postgres database, including RLS/Realtime grants (`test/sql_test.exs`),
compile-time DSL enforcement (`test/resource_verifiers_test.exs`), the
dual-table CRUD/replay flow (`test/dual_table_test.exs`), JWT verification
(`test/auth_test.exs`), the full ZOE LA Chicago suite above, and the
client-facing gateway end to end: `test/gateway_test.exs` (a real Bandit
server, a real `Req` HTTP client, a real signed JWT), plus
`test/export_ontology_test.exs`/`test/ggen_client_sync_test.exs` (the
real `mix ash_supabase.export_ontology` + `mix ggen_igniter.sync`
pipeline, checking the actual generated TypeScript).

## License

MIT, see [LICENSE](LICENSE).
