defmodule AshSupabase.Test.Repo do
  @moduledoc """
  The Ecto/AshPostgres repo used by AshSupabase's own test suite.

  Stands in for "the Postgres database Supabase provisions for your
  project" -- in a real deployment this is your Supabase project's
  connection string (session pooler or direct connection), not a locally
  managed database.
  """

  use AshPostgres.Repo, otp_app: :ash_supabase

  def installed_extensions do
    ["ash-functions", "uuid-ossp", "pgcrypto"]
  end

  # Mirrors the privilege split a real Supabase project has: `anon` and
  # `authenticated` are the roles PostgREST connects as and must never be
  # able to write to an AshSupabase-managed table directly (see
  # `Mix.Tasks.AshSupabase.GenPolicies`). This app's own Postgres role is
  # the only one Ash itself ever connects as.
  def min_pg_version do
    %Version{major: 14, minor: 0, patch: 0}
  end
end
