defmodule AshSupabase.Test.Events.Event do
  @moduledoc """
  The event log: the append-only half of AshSupabase's dual-table
  pattern. Every create/update/destroy performed through a resource that
  uses `AshSupabase.Resource` lands a row here, in the same transaction
  that writes the resource's own "live" projection table.

  `AshEvents.EventLog` generates the `id`/`record_id`/`resource`/
  `action`/`action_type`/`data`/`changed_attributes`/`metadata`/
  `occurred_at`/`version` attributes and the `:create`/`:replay` actions
  automatically -- this module only needs to configure it.
  """

  use Ash.Resource,
    otp_app: :ash_supabase,
    domain: AshSupabase.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.EventLog]

  postgres do
    table "events"
    repo AshSupabase.Test.Repo
  end

  event_log do
    clear_records_for_replay AshSupabase.Test.Events.ClearRecords
    persist_actor_primary_key :user_id, AshSupabase.Test.Accounts.User
    public_fields :all
  end

  actions do
    read :read do
      primary? true
      # AshEvents replays by streaming this action in event order; keyset
      # pagination is what `Ash.Actions.Read.Stream` needs to be allowed
      # to do that.
      pagination keyset?: true
    end

    read :for_record do
      argument :record_id, :uuid, allow_nil?: false
      filter expr(record_id == ^arg(:record_id))
      prepare build(sort: [occurred_at: :asc])
    end
  end
end
