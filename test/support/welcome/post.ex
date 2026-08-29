defmodule AshSupabase.Test.Welcome.Post do
  @moduledoc """
  A staffed "welcome post" -- PRD v26.8.29 §23's `Coverage(W,t)`: how
  many people are currently stationed at post `W` at time `t`, and the
  minimum that must remain for the post to keep functioning.

  `AshSupabase.Test.Welcome.request_escort/4` is the only intended
  caller of `:adjust_coverage`: it computes `current_coverage - 1`
  *before* ever writing, and only proceeds to actually decrement here
  once it has confirmed the post would not drop below
  `minimum_coverage` (or that a replacement has been explicitly
  reserved) -- see that module for the coverage-invariant check itself.
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
    current_action_versions create: 1, adjust_coverage: 1
  end

  postgres do
    table "welcome_posts"
    repo AshSupabase.Test.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :minimum_coverage, :integer, allow_nil?: false, public?: true
    attribute :current_coverage, :integer, default: 0, public?: true
  end

  actions do
    read :read do
      primary? true
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    create :create do
      accept [:name, :minimum_coverage, :current_coverage]
    end

    update :adjust_coverage do
      accept []
      require_atomic? false
      argument :delta, :integer, allow_nil?: false

      change fn changeset, _context ->
        current = Ash.Changeset.get_data(changeset, :current_coverage)
        delta = Ash.Changeset.get_argument(changeset, :delta)
        Ash.Changeset.force_change_attribute(changeset, :current_coverage, current + delta)
      end
    end
  end

  code_interface do
    define :create
    define :adjust_coverage
    define :by_id, args: [:id]
  end
end
