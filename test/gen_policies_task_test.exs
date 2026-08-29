defmodule Mix.Tasks.AshSupabase.GenPoliciesTest do
  @moduledoc """
  Runs the real Mix task (not just `AshSupabase.SQL` in isolation) against
  this app's own domain, so a regression in argument parsing, repo
  grouping, or output formatting fails a normal `mix test` run.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "--dry-run prints RLS/Realtime SQL for every AshSupabase resource and event log" do
    output =
      capture_io(fn ->
        Mix.Task.rerun("ash_supabase.gen_policies", ["--dry-run"])
      end)

    assert output =~ "AshSupabase.Test.Todos.Todo (todos)"
    assert output =~ ~s(ALTER TABLE "todos" ENABLE ROW LEVEL SECURITY;)
    assert output =~ "supabase_realtime"

    assert output =~ "AshSupabase.Test.Events.Event (events)"
    assert output =~ ~s(ALTER TABLE "events" ENABLE ROW LEVEL SECURITY;)
  end

  test "never mentions the users table -- it isn't an AshSupabase.Resource" do
    output =
      capture_io(fn ->
        Mix.Task.rerun("ash_supabase.gen_policies", ["--dry-run"])
      end)

    refute output =~ "(users)"
  end
end
