defmodule AshSupabase.Test.Finance.Account do
  @moduledoc """
  A ledger account (PRD v26.8.29 §9-13, §18-20). `balance_cents` is a
  cached projection -- the authoritative quantity is:

      Balance_n = fold(Transfers_{0..n})

  i.e. the sequence of `:post_debit`/`:post_credit` events this
  resource's dual-table event log accumulates. Only
  `AshSupabase.Ledger.Transfer` may call `:post_debit`/`:post_credit`
  (that's where the `sum(debits) == sum(credits)` invariant is
  enforced, across *both* legs of a transfer, before either leg is
  posted) -- direct callers are limited to opening an account.
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
    current_action_versions create: 1, post_debit: 1, post_credit: 1
  end

  postgres do
    table "finance_accounts"
    repo AshSupabase.Test.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true

    attribute :kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:asset, :liability, :equity, :revenue, :expense]]

    attribute :balance_cents, :integer, default: 0, public?: true
    # Nullable: some accounts (funding/expense) have no individual owner.
    attribute :owner_id, :uuid, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
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
      accept [:name, :kind, :owner_id]
    end

    update :post_debit do
      accept []
      require_atomic? false
      argument :amount_cents, :integer, allow_nil?: false
      argument :transfer_id, :uuid, allow_nil?: false
      argument :counterparty_account_id, :uuid, allow_nil?: false
      argument :memo, :string

      change fn changeset, _context ->
        amount = Ash.Changeset.get_argument(changeset, :amount_cents)
        current = Ash.Changeset.get_data(changeset, :balance_cents)
        Ash.Changeset.force_change_attribute(changeset, :balance_cents, current - amount)
      end
    end

    update :post_credit do
      accept []
      require_atomic? false
      argument :amount_cents, :integer, allow_nil?: false
      argument :transfer_id, :uuid, allow_nil?: false
      argument :counterparty_account_id, :uuid, allow_nil?: false
      argument :memo, :string

      change fn changeset, _context ->
        amount = Ash.Changeset.get_argument(changeset, :amount_cents)
        current = Ash.Changeset.get_data(changeset, :balance_cents)
        Ash.Changeset.force_change_attribute(changeset, :balance_cents, current + amount)
      end
    end
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end

    policy action(:create) do
      authorize_if actor_attribute_equals(:role, "admin")
    end

    # The only actors ever allowed to move money are admins -- this is
    # the policy Chicago Test 3 ("Unauthorized Financial Credit") proves
    # refuses a non-admin actor before either leg is posted.
    policy action([:post_debit, :post_credit]) do
      authorize_if actor_attribute_equals(:role, "admin")
    end
  end

  code_interface do
    define :create
    define :by_id, args: [:id]
  end
end
