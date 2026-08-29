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
       see `AshSupabase.Verifiers.RequireEventSourcing`) to have that
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

  ## Where to look

    * `AshSupabase.Resource` -- the DSL extension resources use to opt in.
    * `AshSupabase.Info` -- introspection over resources using it.
    * `AshSupabase.Auth` -- turn a Supabase-issued JWT into an Ash actor.
    * `Mix.Tasks.AshSupabase.GenPolicies` -- generate the RLS/Realtime SQL.
    * `Mix.Tasks.AshSupabase.Install` -- scaffold a new app onto this stack.

  See the README for a full walkthrough and an end-to-end example.
  """
end
