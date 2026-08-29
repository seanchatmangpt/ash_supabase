defmodule AshSupabase.Test.Kids.StaffingRequirement do
  @moduledoc """
  A single Kids service's staffing need (PRD v26.8.29 §25-26, "the
  architectural crown"): a required headcount of qualified workers for
  one service occurrence, plus how many of those the location can staff
  purely from local capacity.

  When `local_available_workers < required_workers`, the deficit is
  never silently absorbed and never causes "Kids disabled" -- it is
  handed to `AshSupabase.Test.Kids.FulfillmentSolver`, which
  deterministically searches the closed graph of lawful fulfillment
  candidates (starting with `AshSupabase.Test.Federation.PartnerChurch`)
  and either commits a fulfillment plan or produces a receipted, typed
  `BLOCKED:CAPABILITY_CAPACITY` result.
  """

  use Ash.Resource,
    otp_app: :ash_supabase,
    domain: AshSupabase.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshSupabase.Resource, AshEvents.Events]

  supabase do
    realtime?(true)
    expose_via_postgrest?(false)
  end

  events do
    event_log AshSupabase.Test.Events.Event

    current_action_versions create: 1,
                            record_fulfillment: 1,
                            mark_blocked: 1,
                            mark_fulfilled: 1
  end

  postgres do
    table "kids_staffing_requirements"
    repo AshSupabase.Test.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :service_name, :string, allow_nil?: false, public?: true
    attribute :required_workers, :integer, allow_nil?: false, public?: true
    attribute :local_available_workers, :integer, allow_nil?: false, public?: true
    attribute :fulfilled_workers, :integer, default: 0, public?: true

    attribute :status, :atom,
      default: :open,
      public?: true,
      constraints: [one_of: [:open, :fulfilled, :blocked]]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    read :read do
      primary? true
    end

    create :create do
      accept [:service_name, :required_workers, :local_available_workers]
    end

    update :record_fulfillment do
      accept []
      require_atomic? false

      argument :additional_workers, :integer, allow_nil?: false

      change fn changeset, _context ->
        current = Ash.Changeset.get_data(changeset, :fulfilled_workers)
        added = Ash.Changeset.get_argument(changeset, :additional_workers)
        Ash.Changeset.force_change_attribute(changeset, :fulfilled_workers, current + added)
      end
    end

    update :mark_blocked do
      accept []
      change set_attribute(:status, :blocked)
    end

    update :mark_fulfilled do
      accept []
      change set_attribute(:status, :fulfilled)
    end
  end

  code_interface do
    define :create
    define :record_fulfillment, args: [:additional_workers]
    define :mark_blocked
    define :mark_fulfilled
  end

  calculations do
    # Positive means local capacity alone cannot cover this requirement
    # and the fulfillment solver must be consulted; <= 0 means no
    # federation is needed at all.
    calculate :deficit, :integer, expr(required_workers - local_available_workers)
  end
end
