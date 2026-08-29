defmodule AshSupabase do
  @moduledoc """
  Route every Supabase CRUD operation through Ash, with a dual-table
  event-sourcing data layer.

  Supabase is Postgres plus three services layered directly on top of it:
  PostgREST (a REST API generated from your schema), Realtime (a
  logical-replication feed clients can subscribe to), and GoTrue (auth,
  which is just a Postgres-backed user table plus JWT issuance). None of
  those services care *how* a row got written -- they read the database.

  `AshSupabase` uses that fact. Instead of letting PostgREST or a Supabase
  client library write directly to your tables, every resource:

    1. Is declared as a normal `Ash.Resource` with `AshPostgres.DataLayer`
       -- its rows live in the same Postgres database your Supabase
       project serves, in an ordinary table PostgREST/Realtime can see.
    2. Also carries the `AshEvents.Events` extension, pointed at a shared
       event log resource. Every `create`/`update`/`destroy` action is
       wrapped so that, in one transaction, an immutable event is
       appended to the event log *and* the resource's own "live" table
       is written. Two tables, one write path -- a dual-table event
       sourcing pattern.
    3. Is required (enforced at compile time by `AshSupabase.Resource`,
       see `AshSupabase.Transformers.RequireEventSourcing`) to have that
       wiring in place. A resource can't opt out of the event log while
       still calling itself an `AshSupabase.Resource`.
    4. Has Row Level Security locked down (see
       `Mix.Tasks.AshSupabase.GenPolicies`) so the `anon`/`authenticated`
       Postgres roles PostgREST connects as cannot write to the table at
       all -- only the role your Ash application connects as can. Direct
       REST/Realtime writes are refused by Postgres itself, not by
       application convention.

  The net effect: the *only* path that produces a row in a Supabase table
  is an Ash action, and every such write is simultaneously durable event
  history you can audit or replay (`AshEvents`) to rebuild a table's
  state, migrate to a new projection, or debug what happened and why.

  Locking PostgREST's writes down only answers half the question, though
  -- "how do we stop a client writing around Ash." It says nothing about
  how a client is supposed to write *at all*, given it still only speaks
  the Supabase SDK it already knows, with zero awareness that Ash or
  Elixir exist. `AshSupabase.Gateway` plus `mix
  ash_supabase.export_ontology` (feeding `ggen_igniter`'s
  ontology-to-code pipeline, see `priv/ggen/ash-supabase-client-pack`)
  are that other half: a resource opts a subset of its actions into
  `supabase do gateway_actions [...] end`, and gets back a real,
  generated, typed TypeScript client (`createTodo(supabase, {...})`)
  that a browser/mobile developer imports and calls exactly like any
  other Supabase helper -- routed, behind one generic Edge Function
  proxy, straight into the same Ash policy/action pipeline every other
  path in this library already goes through.

  ## Where to look

    * `AshSupabase.Resource` -- the DSL extension resources use to opt in.
    * `AshSupabase.Info` -- introspection over resources using it.
    * `AshSupabase.Auth` -- turn a Supabase-issued JWT into an Ash actor.
    * `AshSupabase.Gateway` -- the HTTP surface a Supabase-only client
      (via a generated Edge Function) reaches for a write.
    * `Mix.Tasks.AshSupabase.ExportOntology` -- projects gateway-exposed
      actions into the ontology `mix ggen_igniter.sync` renders into a
      typed TypeScript client (`mix ash_supabase.gen_client` runs both).
    * `Mix.Tasks.AshSupabase.GenPolicies` -- generate the RLS/Realtime SQL.
    * `Mix.Tasks.AshSupabase.Install` -- scaffold a new app onto this stack.

  See the README for a full walkthrough and an end-to-end example.
  """
end
