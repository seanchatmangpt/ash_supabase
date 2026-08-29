# Changelog

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
