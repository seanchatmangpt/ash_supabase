# Changelog

## Unreleased -- clients only ever see Supabase

Closes the gap in the previous entry below: locking PostgREST's writes
down answered "how do we stop a client writing around Ash," but never
answered "then how does a client write *at all*, given it still only
speaks the Supabase SDK it already knows." This adds the other half.

- `AshSupabase.Resource`'s `supabase do ... end` gains `gateway_actions`
  -- the action names a resource opts into being reachable through the
  gateway (enforced at compile time: naming an action the resource
  doesn't have is a `Spark.Error.DslError`, same discipline as every
  other `AshSupabase.Resource` guarantee).
- `AshSupabase.Gateway` -- a `Plug.Router` implementing the one HTTP
  contract a Supabase-only client (via a generated Edge Function) needs:
  `POST /` with `{resource, action, params}` and a `Authorization:
  Bearer <supabase-jwt>` header, verified with the same
  `AshSupabase.Auth.verify/3` this library already shipped. Dispatches
  `:create`/`:update`/`:destroy` through the resource's real Ash
  actions/policies; maps Ash's error classes to HTTP status honestly,
  including the `404`-not-`403` case for a record the actor can't read
  (Ash's own "never confirm existence" convention, preserved rather than
  papered over).
- `mix ash_supabase.export_ontology` -- introspects every
  `gateway_actions`-opted-in resource into an RDF/Turtle ontology
  (attribute names and JSON-representable types only, no Ash/Elixir
  vocabulary), the "closed model" a client is allowed to reach.
- A real `ggen_igniter` pack (`priv/ggen/ash-supabase-client-pack`:
  ontology, two SPARQL queries, one EEx template) that
  `mix ggen_igniter.sync` (aliased as `mix ash_supabase.gen_client`,
  which runs both steps) deterministically projects into a typed
  TypeScript client -- one function + params interface per gateway
  action, one return-type interface per resource, generated fresh from
  the live domain every run, never hand-maintained.
- `priv/supabase/functions/ash-gateway/index.ts` -- the one static, generic
  Deno Edge Function every generated client function calls through;
  never regenerated, since it is entirely resource-agnostic.

Verified end to end, not just unit-tested in isolation:
`test/gateway_test.exs` runs a real `Bandit` server and a real `Req` HTTP
client against real Postgres with a real signed JWT (create, update,
destroy, cross-actor refusal, expired/missing token, an unexposed real
action correctly indistinguishable from a nonexistent one);
`test/export_ontology_test.exs` and `test/ggen_client_sync_test.exs` run
the real `mix ash_supabase.export_ontology` and real
`mix ggen_igniter.sync` (real SPARQL, real oxigraph engine, real disk
write) and check the actual generated Turtle/TypeScript content,
including that the generated code itself never mentions Ash, Elixir, or
Reactor.

Two real bugs caught and fixed along the way, worth naming:

- `Ash.get/3` for a record the caller can't read returns
  `Ash.Error.Invalid` wrapping `Ash.Error.Query.NotFound` -- not
  `Ash.Error.Forbidden` -- because Ash deliberately never confirms a
  record you aren't allowed to see actually exists. The gateway's error
  mapping now recurses into wrapped error lists to find that case and
  returns `404`, not a naive `403` (or a worse-than-useless `422` from
  the outer class alone).
- `lib/ash_supabase/reactors/ledger_transfer.ex` referenced
  `AshSupabase.Test.Ontology` (and, transitively, every other
  `AshSupabase.Test.*` fixture the ZOE LA proving ground defines) from
  inside `lib/` -- code that ships to every consumer of this package,
  compiled in every environment. `test/support` is only on the compile
  path for `MIX_ENV=test` (see `mix.exs`'s `elixirc_paths/1`), so `mix
  compile` in `:dev`/`:prod` -- exactly what `mix ggen_igniter.sync`'s
  own reconciliation step shells out, and exactly what a real downstream
  consumer's `mix deps.compile` would do -- failed outright with
  `UndefinedFunctionError`. `mix test` alone never caught this, because
  `:test` env happens to compile `test/support` too. Moved the whole
  module to `test/support/finance/transfer.ex`, where every one of its
  actual dependencies already lives; `mix compile` in `:dev` is now
  clean, which it was not before this fix.

## Unreleased -- ZOE LA Chicago proving ground (v26.8.29 PRD/ARD)

Implements the v26.8.29 PRD's corrected architecture end to end against a
real church-operations domain: no LLM in production, Supabase is
transport/projection only, Ash is authoritative, `Ash.Reactor` (plus
`AshSupabase.Transaction` for dynamic-shaped processes) executes
deterministic autonomics.

- `AshSupabase.Ledger.Transfer` -- a real `Ash.Reactor`: verifies
  `sum(debits) == sum(credits)` before opening any database transaction
  (zero writes on an unbalanced construction), posts both legs plus a
  receipt inside one `Ash.DataLayer.transaction/5` call, so an
  unauthorized actor's policy refusal on either leg rolls the whole
  transfer back.
- `AshSupabase.Transaction` -- closes a real gap: wrapping several Ash
  action calls in a raw `Repo.transaction/1` silently drops Ash's own
  notifications. This holds them (via Ash's own
  `:ash_started_transaction?`/`:ash_notifications` process-dictionary
  contract) until the transaction actually commits, then dispatches them
  -- the same "notification only after commit" guarantee `Ash.Reactor`
  gets for free, given to plain deterministic processes whose step count
  isn't known until runtime (a federation candidate walk, an arbitrary
  posting list).
- `AshSupabase.Replay` -- generic, resource-agnostic event/state replay
  equivalence: `state_hash/2` hashes any Ash resource's public attributes
  deterministically; `compare/2` says `:alive` or `{:drift, ...}`.
- `AshSupabase.Test.Obligations.Obligation` -- the shared
  Threshold→Signal→Classification→Owner→Obligation→Action→Receipt→NextState
  grammar every Welcome, Infant Room, Escort, Care, and Recovery scenario
  instantiates; no obligation this resource creates can silently
  disappear -- every one reaches a closed, typed status.
- `AshSupabase.Test.Kids.FulfillmentSolver` -- the architectural crown:
  deterministically walks a closed, nearest-verified-first candidate
  graph of partner churches to cover a local Kids-staffing deficit,
  reserving capacity atomically or producing a receipted, typed
  `BLOCKED:CAPABILITY_CAPACITY` refusal with zero partial reservations --
  never "Kids disabled".
- A complete worked ZOE LA "Chicago suite": 17 numbered PRD acceptance
  tests plus the §46-47 crown scenario, all against real Postgres, no
  mocks -- see the README's "ZOE LA Chicago proving ground" table for the
  full test-file index.

## 0.1.0

Initial release.

- `AshSupabase.Resource` -- a Spark DSL extension resources use to opt
  into the dual-table event-sourcing pattern. Compilation fails outright
  (`AshSupabase.Transformers.RequirePostgresDataLayer`,
  `AshSupabase.Transformers.RequireEventSourcing`) unless a resource is
  backed by `AshPostgres.DataLayer` *and* also carries `AshEvents.Events`
  with an `event_log` configured -- there is no way to declare a resource
  "Supabase-fronted" without every create/update/destroy also producing
  an event.
- `AshSupabase.Info` -- introspection over `supabase do ... end`
  configuration and every `AshSupabase.Resource` across an app's domains.
- `AshSupabase.SQL` / `mix ash_supabase.gen_policies` -- generates an
  idempotent Ecto migration that enables Row Level Security and revokes
  all privileges from the `anon`/`authenticated` Postgres roles for every
  AshSupabase-managed table (and every AshEvents event log,
  unconditionally), adds a read-only RLS policy for resources that opt
  in with `expose_via_postgrest? true`, and adds/removes
  `supabase_realtime` publication membership per resource.
- `AshSupabase.Auth` / `AshSupabase.Auth.HS256` -- verifies a
  Supabase-issued JWT (legacy shared-secret model) with no third-party
  JWT dependency, and builds the Ash actor struct policies authorize
  against. Pluggable via the `AshSupabase.Auth` behaviour for
  asymmetric-key (JWKS) Supabase projects.
- `mix ash_supabase.install` -- Igniter installer; wires the formatter
  and scaffolds the event log resource (`--example` also scaffolds a
  fully wired example resource).
- A complete worked example (`test/support`) -- `Accounts.User`,
  `Events.Event`, `Todos.Todo` -- exercised end to end against a real
  Postgres database: create/update/destroy produce both table rows and
  the matching second/third event, policies refuse cross-actor access
  before either table is touched, and event replay reproduces live
  state from the event log alone.
