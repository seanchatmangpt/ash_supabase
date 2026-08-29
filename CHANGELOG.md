# Changelog

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
