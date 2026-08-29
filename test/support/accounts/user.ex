defmodule AshSupabase.Test.Accounts.User do
  @moduledoc """
  A minimal stand-in for the row Supabase Auth (GoTrue) maintains in
  `auth.users` -- just enough (a uuid primary key + email) to act as an
  actor for policies and to be the `persist_actor_primary_key` target on
  the event log. `AshSupabase.Auth` maps a verified Supabase JWT's `sub`
  claim onto this id.

  This resource intentionally does *not* use `AshSupabase.Resource`: it
  models an externally-owned table (Supabase Auth writes to
  `auth.users`, not Ash), so it isn't part of the dual-table event
  sourcing contract that resource extends only to app-owned tables.
  """

  use Ash.Resource,
    otp_app: :ash_supabase,
    domain: AshSupabase.Test.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "users"
    repo AshSupabase.Test.Repo
  end

  attributes do
    # Writable (unlike a typical uuid_primary_key) because this id must
    # match the id Supabase Auth already assigned in `auth.users` --
    # it's mirrored here, not generated here.
    uuid_primary_key :id, writable?: true
    attribute :email, :string, allow_nil?: false, public?: true
    attribute :role, :string, default: "authenticated", public?: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:id, :email, :role]
    end
  end
end
