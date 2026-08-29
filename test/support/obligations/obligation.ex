defmodule AshSupabase.Test.Obligations.Obligation do
  @moduledoc """
  The generic obligation grammar (PRD v26.8.29 §27):

      Threshold -> Signal -> Classification -> Owner -> Obligation
        -> Action -> Receipt -> NextState

  Every one of Welcome, Infant Room, Escort/Coverage, Care, and Recovery
  is an instance of *this one resource* -- `kind` selects which
  scenario an obligation belongs to, `status` tracks its position in
  the shared lifecycle, and `outcome_label` carries each scenario's own
  terminal vocabulary ("INFORMED", "ROUTED", "NOT_APPLICABLE",
  "COMPLETED", "ESCORTED", "SERVICED", "HANDED_OFF", ...) as free text
  set by whichever process closes the obligation.

  §27's hard invariant -- "No obligation may silently disappear" --
  means every obligation this resource ever creates must eventually
  reach a *closed, typed* status (`:completed`, `:declined`, or
  `:blocked`); `:open`/`:owner_assigned`/`:in_progress` are the only
  transient states a caller may leave an obligation in mid-transaction,
  never as a process's final word.
  """

  use Ash.Resource,
    otp_app: :ash_supabase,
    domain: AshSupabase.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshSupabase.Resource, AshEvents.Events],
    authorizers: [Ash.Policy.Authorizer]

  supabase do
    realtime?(true)
    expose_via_postgrest?(false)
  end

  events do
    event_log AshSupabase.Test.Events.Event
    current_action_versions create: 1, assign_owner: 1, complete: 1, decline: 1, block: 1
  end

  postgres do
    table "obligations"
    repo AshSupabase.Test.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:welcome, :infant_room, :escort, :care, :recovery]]

    # The person/session this obligation is about.
    attribute :subject_id, :uuid, allow_nil?: false, public?: true

    # Nullable until an owner/actor is assigned to carry the obligation.
    attribute :owner_id, :uuid, public?: true

    attribute :status, :atom,
      allow_nil?: false,
      default: :open,
      public?: true,
      constraints: [
        one_of: [:open, :owner_assigned, :in_progress, :completed, :declined, :blocked]
      ]

    # The PRD's kind-specific terminal vocabulary, e.g. "INFORMED",
    # "ROUTED", "NOT_APPLICABLE", "COMPLETED" -- free text, set by the
    # calling process, not constrained here (each scenario owns its own
    # vocabulary; this resource only owns the shared lifecycle shape).
    attribute :outcome_label, :string, public?: true

    attribute :blocked_reason, :string, public?: true

    attribute :metadata, :map, default: %{}, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    read :read do
      primary? true
    end

    read :for_subject_and_kind do
      argument :subject_id, :uuid, allow_nil?: false
      argument :kind, :atom, allow_nil?: false
      filter expr(subject_id == ^arg(:subject_id) and kind == ^arg(:kind))
    end

    create :create do
      accept [:kind, :subject_id, :metadata]
    end

    update :assign_owner do
      accept [:owner_id]
      change set_attribute(:status, :owner_assigned)
    end

    update :complete do
      accept [:outcome_label]
      change set_attribute(:status, :completed)
    end

    update :decline do
      accept [:outcome_label]
      change set_attribute(:status, :declined)
    end

    update :block do
      accept [:blocked_reason]
      change set_attribute(:status, :blocked)
    end
  end

  policies do
    # Internal-process-driven, not directly user-mutated in these
    # tests: every caller (Welcome, Care, Recovery, ...) writes as a
    # trusted system actor, so presence is all that is required here.
    policy always() do
      authorize_if actor_present()
    end
  end

  code_interface do
    define :create
    define :assign_owner
    define :complete
    define :decline
    define :block
    define :for_subject_and_kind, args: [:subject_id, :kind]
  end
end
