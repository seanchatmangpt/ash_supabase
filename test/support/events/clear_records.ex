defmodule AshSupabase.Test.Events.ClearRecords do
  @moduledoc """
  Implements `AshEvents.ClearRecordsForReplay` for the test domain.

  Before AshEvents replays the event log it needs every AshSupabase-managed
  projection table wiped, so the replayed events rebuild state from
  nothing rather than double-applying on top of what's already there.
  We truncate every table that belongs to a resource using
  `AshSupabase.Resource` -- found generically via `AshSupabase.Info`, so
  this module doesn't need updating each time a new resource is added.
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
      Ecto.Adapters.SQL.query!(Repo, ~s(TRUNCATE TABLE "#{table}" RESTART IDENTITY CASCADE))
    end)

    :ok
  end
end
