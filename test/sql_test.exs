defmodule AshSupabase.SQLTest do
  use ExUnit.Case, async: true

  alias AshSupabase.SQL

  describe "resource_statements/2" do
    test "a default (locked-down, realtime) resource: RLS + revoke + realtime, no grants" do
      %{up: up, down: down} =
        SQL.resource_statements("todos", %{
          expose_via_postgrest?: false,
          realtime?: true,
          rls_authenticated_select?: false
        })

      up_sql = Enum.join(up, "\n")
      assert up_sql =~ ~s(ALTER TABLE "todos" ENABLE ROW LEVEL SECURITY;)
      assert up_sql =~ ~s(REVOKE ALL ON "todos" FROM anon, authenticated;)
      assert up_sql =~ ~s(ADD TABLE "todos")
      refute up_sql =~ "GRANT SELECT"

      down_sql = Enum.join(down, "\n")
      assert down_sql =~ ~s(DROP TABLE "todos")
      assert down_sql =~ ~s(ALTER TABLE "todos" DISABLE ROW LEVEL SECURITY;)
    end

    test "expose_via_postgrest?: true grants SELECT to anon only by default" do
      %{up: up} =
        SQL.resource_statements("public_posts", %{
          expose_via_postgrest?: true,
          realtime?: false,
          rls_authenticated_select?: false
        })

      up_sql = Enum.join(up, "\n")
      assert up_sql =~ "GRANT SELECT ON \"public_posts\" TO anon;"
      refute up_sql =~ "GRANT SELECT ON \"public_posts\" TO authenticated;"
      assert up_sql =~ "CREATE POLICY"
      refute up_sql =~ "supabase_realtime"
    end

    test "rls_authenticated_select?: true additionally grants the authenticated role" do
      %{up: up} =
        SQL.resource_statements("public_posts", %{
          expose_via_postgrest?: true,
          realtime?: false,
          rls_authenticated_select?: true
        })

      up_sql = Enum.join(up, "\n")
      assert up_sql =~ "GRANT SELECT ON \"public_posts\" TO anon;"
      assert up_sql =~ "GRANT SELECT ON \"public_posts\" TO authenticated;"
    end

    test "never generates a direct INSERT/UPDATE/DELETE grant, regardless of config" do
      for expose? <- [true, false], read_only? <- [true, false] do
        %{up: up} =
          SQL.resource_statements("t", %{
            expose_via_postgrest?: expose?,
            realtime?: false,
            rls_authenticated_select?: read_only?
          })

        up_sql = Enum.join(up, "\n")
        refute up_sql =~ ~r/GRANT\s+(INSERT|UPDATE|DELETE)/i
      end
    end
  end

  describe "event_log_statements/1" do
    test "always fully locked down, never granted, never realtime" do
      %{up: up} = SQL.event_log_statements("events")
      up_sql = Enum.join(up, "\n")

      assert up_sql =~ ~s(ALTER TABLE "events" ENABLE ROW LEVEL SECURITY;)
      assert up_sql =~ ~s(REVOKE ALL ON "events" FROM anon, authenticated;)
      refute up_sql =~ "GRANT"
      refute up_sql =~ "supabase_realtime"
    end
  end
end
