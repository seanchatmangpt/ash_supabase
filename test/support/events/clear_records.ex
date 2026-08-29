defmodule AshSupabase.Test.Events.ClearRecords do
  @moduledoc """
  Implements `AshEvents.ClearRecordsForReplay` for the test domain.

  Before AshEvents replays the event log it needs every AshSupabase-managed
  projection table wiped, so the replayed events rebuild state from
  nothing rather than double-applying on top of what's already there.
  We delete every row from every table that belongs to a resource using
  `AshSupabase.Resource` -- found generically via `AshSupabase.Info`, so
  this module doesn't need updating each time a new resource is added.

  Deliberately `DELETE FROM`, not `TRUNCATE`: this test suite runs many
  resources' tests concurrently (`async: true`) inside Ecto's SQL
  Sandbox, each in its own isolated transaction against shared
  connections. `TRUNCATE` takes an `ACCESS EXCLUSIVE` table lock that a
  concurrently-sandboxed test touching the same table cannot coexist
  with -- it reliably deadlocks under load. `DELETE FROM` only takes
  row-level locks, which the sandbox's per-test transaction isolation
  handles the way it's designed to.
  """

  use AshEvents.ClearRecordsForReplay

  alias AshSupabase.Test.Repo

  @impl true
  def clear_records!(_opts) do
    :ash_supabase
    |> AshSupabase.Info.supabase_resources()
    |> Enum.map(&AshPostgres.DataLayer.Info.table/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.each(fn table ->
      Ecto.Adapters.SQL.query!(Repo, ~s(DELETE FROM "#{table}"))
    end)

    :ok
  end
end
