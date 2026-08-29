defmodule AshSupabase.SQL do
  @moduledoc """
  Builds the idempotent SQL statements that make "all Supabase CRUD goes
  through Ash" true at the database level, rather than by convention.

  Used by `Mix.Tasks.AshSupabase.GenPolicies` to write a migration; split
  out so the generation logic itself is directly testable without going
  through Mix.
  """

  @postgrest_roles ~w(anon authenticated)
  @realtime_publication "supabase_realtime"

  @doc """
  All statements to lock a table down to Ash-only writes, for a resource
  using `AshSupabase.Resource`. Always emitted, regardless of
  `expose_via_postgrest?`, before any read grant is added.
  """
  def lockdown_statements(table) do
    [
      ~s(ALTER TABLE #{q(table)} ENABLE ROW LEVEL SECURITY;),
      revoke_all(table)
    ]
  end

  @doc """
  All statements to lock down a table that should never be reachable via
  PostgREST at all (event logs, and any resource that leaves
  `expose_via_postgrest?` at its default `false`).
  """
  def deny_all_statements(table) do
    lockdown_statements(table)
  end

  @doc """
  Statements granting a read-only PostgREST policy, for a resource with
  `expose_via_postgrest?: true`. `roles` is the list of Postgres roles to
  grant `SELECT` to (see `AshSupabase.Info.rls_authenticated_select?/1`).

  The generated policy is intentionally permissive (`USING (true)`) as a
  starting point -- PostgREST reads are meant for genuinely public data;
  anything that needs row filtering belongs behind an Ash read action
  with its own `policies`, not a hand-maintained SQL predicate.
  """
  def read_only_grant_statements(table, roles) when is_list(roles) do
    policy_name = "#{table}_ash_supabase_select"

    Enum.flat_map(roles, fn role ->
      [
        ~s(GRANT SELECT ON #{q(table)} TO #{role};)
      ]
    end) ++
      [
        drop_policy_if_exists(table, policy_name),
        ~s[CREATE POLICY #{qi(policy_name)} ON #{q(table)} ] <>
          ~s[FOR SELECT TO #{Enum.join(roles, ", ")} USING (true);]
      ]
  end

  @doc "Idempotently add `table` to the `supabase_realtime` publication."
  def realtime_statements(table) do
    [
      """
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = '#{@realtime_publication}') THEN
          CREATE PUBLICATION #{@realtime_publication};
        END IF;
      END $$;
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_publication_tables
          WHERE pubname = '#{@realtime_publication}' AND tablename = '#{table}'
        ) THEN
          EXECUTE 'ALTER PUBLICATION #{@realtime_publication} ADD TABLE #{q(table)}';
        END IF;
      END $$;
      """
    ]
  end

  @doc "Idempotently remove `table` from the `supabase_realtime` publication."
  def remove_realtime_statements(table) do
    [
      """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM pg_publication_tables
          WHERE pubname = '#{@realtime_publication}' AND tablename = '#{table}'
        ) THEN
          EXECUTE 'ALTER PUBLICATION #{@realtime_publication} DROP TABLE #{q(table)}';
        END IF;
      END $$;
      """
    ]
  end

  @doc """
  Full up/down statement lists for one `AshSupabase.Resource`, given its
  table name and `AshSupabase.Info` configuration.
  """
  def resource_statements(table, config) do
    read_grant =
      if config.expose_via_postgrest? do
        roles = if config.rls_authenticated_select?, do: @postgrest_roles, else: ["anon"]
        read_only_grant_statements(table, roles)
      else
        []
      end

    realtime = if config.realtime?, do: realtime_statements(table), else: []

    up = lockdown_statements(table) ++ read_grant ++ realtime

    down =
      if(config.realtime?, do: remove_realtime_statements(table), else: []) ++
        [~s(ALTER TABLE #{q(table)} DISABLE ROW LEVEL SECURITY;)]

    %{up: up, down: down}
  end

  @doc "Full up/down statement lists locking an event-log table down completely."
  def event_log_statements(table) do
    %{
      up: deny_all_statements(table),
      down: [~s(ALTER TABLE #{q(table)} DISABLE ROW LEVEL SECURITY;)]
    }
  end

  defp revoke_all(table) do
    ~s(REVOKE ALL ON #{q(table)} FROM #{Enum.join(@postgrest_roles, ", ")};)
  end

  defp drop_policy_if_exists(table, policy_name) do
    ~s(DROP POLICY IF EXISTS #{qi(policy_name)} ON #{q(table)};)
  end

  # Quote a table identifier (unqualified -- PostgREST-exposed tables
  # live in the `public` schema, same as everything else Ash migrates).
  defp q(table), do: ~s("#{table}")

  # Quote a bare identifier (policy names, etc).
  defp qi(name), do: ~s("#{name}")
end
