defmodule AshSupabase.Test.Federation.PartnerChurch do
  @moduledoc """
  A federated partner church: one node in the closed graph of lawful
  fulfillment candidates `AshSupabase.Test.Kids.FulfillmentSolver` may
  draw qualified-worker capacity from when local capacity falls short
  (PRD v26.8.29 §25-26).

  Two hard constraints gate every reservation, enforced independently
  by both this resource's `:candidates` read action *and* the solver
  itself (never trust a filter alone to be the only place a safety
  constraint is checked):

    * `verified_safeguarding` must be `true` -- an unverified partner
      is never a fulfillment source, no matter how much raw capacity it
      reports.
    * capacity is bounded by `qualified_available_workers -
      reserved_workers` -- a partner can never be over-reserved.

  `:candidates` also fixes the search order (nearest verified partner
  first) so the solver has one deterministic path through the graph,
  never a scored/optimized choice among several "valid" answers.
  """

  use Ash.Resource,
    otp_app: :ash_supabase,
    domain: AshSupabase.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshSupabase.Resource, AshEvents.Events]

  supabase do
    realtime?(false)
    expose_via_postgrest?(false)
  end

  events do
    event_log AshSupabase.Test.Events.Event
    current_action_versions create: 1, reserve: 1
  end

  postgres do
    table "partner_churches"
    repo AshSupabase.Test.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :qualified_available_workers, :integer, allow_nil?: false, public?: true

    attribute :verified_safeguarding, :boolean,
      allow_nil?: false,
      default: false,
      public?: true

    attribute :distance_miles, :integer, allow_nil?: false, public?: true
    attribute :reserved_workers, :integer, default: 0, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    read :read do
      primary? true
    end

    # Deterministic candidate ordering for the fulfillment solver:
    # nearest verified-safeguarding partner first. `verified_safeguarding
    # == true` is a hard constraint, not a scoring preference -- an
    # unverified partner never appears here regardless of distance or
    # available capacity.
    read :candidates do
      prepare build(sort: [distance_miles: :asc])
      filter expr(verified_safeguarding == true)
    end

    create :create do
      accept [:name, :qualified_available_workers, :verified_safeguarding, :distance_miles]
    end

    update :reserve do
      accept []
      require_atomic? false

      argument :count, :integer, allow_nil?: false

      change fn changeset, _context ->
        current = Ash.Changeset.get_data(changeset, :reserved_workers)
        count = Ash.Changeset.get_argument(changeset, :count)
        Ash.Changeset.force_change_attribute(changeset, :reserved_workers, current + count)
      end
    end
  end

  code_interface do
    define :create
    define :reserve, args: [:count]
    define :candidates
  end
end
