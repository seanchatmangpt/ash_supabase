defmodule AshSupabase.Test.Todos.Todo do
  @moduledoc """
  The example "app" resource: a Supabase-fronted table whose only write
  path is Ash.

    * `AshPostgres.DataLayer` -- the live/projection table (`todos`)
      PostgREST and Supabase Realtime would normally read straight from.
    * `AshEvents.Events`, pointed at `AshSupabase.Test.Events.Event` --
      every create/update/destroy also appends an event, atomically.
    * `AshSupabase.Resource` -- enforces the two points above are wired
      together, and declares this table's Supabase exposure (realtime
      publication membership; no direct PostgREST grants).
    * `Ash.Policy.Authorizer` -- since PostgREST/RLS is locked out of
      writes for this table (see `Mix.Tasks.AshSupabase.GenPolicies`),
      Ash policies are the *only* authorization gate left. Every request
      -- whether it originates from a Phoenix controller, a LiveView, or
      an `AshJsonApi`/`AshGraphql` endpoint -- runs through these.
  """

  use Ash.Resource,
    otp_app: :ash_supabase,
    domain: AshSupabase.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshSupabase.Resource, AshEvents.Events],
    authorizers: [Ash.Policy.Authorizer]

  supabase do
    # Live todo changes stream to Supabase Realtime as soon as Ash
    # commits them -- clients never write the table themselves.
    realtime?(true)
    expose_via_postgrest?(false)
  end

  events do
    event_log AshSupabase.Test.Events.Event
    current_action_versions create: 1, update: 1, destroy: 1
  end

  postgres do
    table "todos"
    repo AshSupabase.Test.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :completed, :boolean, default: false, public?: true
    attribute :user_id, :uuid, allow_nil?: false, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, AshSupabase.Test.Accounts.User do
      source_attribute :user_id
      define_attribute? false
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:title, :user_id]
    end

    update :update do
      accept [:title, :completed]
    end

    update :complete do
      accept []
      change set_attribute(:completed, true)
    end
  end

  policies do
    # Every Todo action requires *some* actor -- there is no anonymous
    # path left now that PostgREST can't touch this table directly.
    policy always() do
      authorize_if actor_present()
    end

    policy action_type(:create) do
      # You may only ever create todos for yourself.
      authorize_if expr(^actor(:id) == user_id)
    end

    policy action_type([:read, :update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  code_interface do
    define :create
    define :update
    define :complete
    define :destroy
    define :read, action: :read
    define :get, action: :read, get_by: [:id]
  end
end
