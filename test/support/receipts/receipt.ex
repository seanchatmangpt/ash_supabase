defmodule AshSupabase.Test.Receipts.Receipt do
  @moduledoc """
  The terminal, immutable record every consequential Reactor execution
  produces (PRD v26.8.29 §38 "Required Receipts").

  A receipt is written *inside* the same transaction as the consequence
  it describes (see `AshSupabase.Ledger.PostTransfer` and the
  obligation/kids-fulfillment reactors) -- if the transaction rolls
  back, the receipt never exists, satisfying §5.5
  ("Notification ⇒ CommittedConsequence"). There is no update or
  destroy action: a receipt, once committed, cannot be revised.

  Still goes through `AshSupabase.Resource` + `AshEvents.Events` like
  every other table here -- there is no special-cased "trusted internal
  table" that skips the dual-table/RLS-lockdown story.
  """

  use Ash.Resource,
    otp_app: :ash_supabase,
    domain: AshSupabase.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshSupabase.Resource, AshEvents.Events]

  supabase do
    # Receipts are an audit trail, not a client-facing live feed.
    realtime?(false)
    expose_via_postgrest?(false)
  end

  events do
    event_log AshSupabase.Test.Events.Event
    current_action_versions create: 1
  end

  postgres do
    table "receipts"
    repo AshSupabase.Test.Repo
  end

  attributes do
    uuid_primary_key :id

    # What this receipt is about.
    attribute :subject_type, :string, allow_nil?: false, public?: true
    attribute :subject_id, :string, allow_nil?: false, public?: true

    # Identity needed to judge/replay the decision later (§33, §38).
    attribute :ontology_version, :string, allow_nil?: false, public?: true
    attribute :policy_id, :string, public?: true
    attribute :actor_type, :string, public?: true
    attribute :actor_id, :string, public?: true
    attribute :request_id, :string, allow_nil?: false, public?: true
    attribute :process, :string, allow_nil?: false, public?: true

    # Admission + outcome (§40 typed failures).
    attribute :admission, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:admitted, :refused, :blocked]]

    attribute :outcome, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:success, :refused, :blocked, :error]]

    attribute :refusal_type, :string, public?: true

    # State/ledger/replay evidence.
    attribute :source_state_version, :integer, public?: true
    attribute :state_version, :integer, public?: true
    attribute :events_created, :integer, default: 0, public?: true
    attribute :financial_postings, {:array, :map}, default: [], public?: true
    attribute :notification_ids, {:array, :string}, default: [], public?: true
    attribute :replay_identity, :map, default: %{}, public?: true
    attribute :zero_write_verified, :boolean, default: false, public?: true

    attribute :metadata, :map, default: %{}, public?: true

    create_timestamp :occurred_at
  end

  actions do
    read :read do
      primary? true
      pagination keyset?: true, required?: false
    end

    read :for_subject do
      argument :subject_type, :string, allow_nil?: false
      argument :subject_id, :string, allow_nil?: false
      filter expr(subject_type == ^arg(:subject_type) and subject_id == ^arg(:subject_id))
      prepare build(sort: [occurred_at: :asc])
    end

    create :create do
      accept [
        :subject_type,
        :subject_id,
        :ontology_version,
        :policy_id,
        :actor_type,
        :actor_id,
        :request_id,
        :process,
        :admission,
        :outcome,
        :refusal_type,
        :source_state_version,
        :state_version,
        :events_created,
        :financial_postings,
        :notification_ids,
        :replay_identity,
        :zero_write_verified,
        :metadata
      ]
    end
  end

  code_interface do
    define :create
    define :for_subject, args: [:subject_type, :subject_id]
  end
end
