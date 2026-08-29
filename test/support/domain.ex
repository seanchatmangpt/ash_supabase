defmodule AshSupabase.Test.Domain do
  @moduledoc """
  The Ash domain grouping the ZOE LA "Chicago proving ground" resources
  (PRD v26.8.29) used to exercise AshSupabase end to end: identity,
  receipts, the double-entry ledger, the generic obligation/coverage
  grammar (Welcome, Care, Recovery, Escort), and Kids capacity +
  federation.
  """

  use Ash.Domain, otp_app: :ash_supabase

  resources do
    resource AshSupabase.Test.Accounts.User
    resource AshSupabase.Test.Events.Event
    resource AshSupabase.Test.Todos.Todo
    resource AshSupabase.Test.Receipts.Receipt

    # Finance (§9-13, §18-20)
    resource AshSupabase.Test.Finance.Account

    # Generic obligation grammar (§27) -- Welcome, Infant Room, Care,
    # Recovery, Escort/Coverage all instantiate this one resource.
    resource AshSupabase.Test.Obligations.Obligation
    resource AshSupabase.Test.Welcome.Post

    # Kids capacity + federation (§25-26, the architectural crown)
    resource AshSupabase.Test.Kids.StaffingRequirement
    resource AshSupabase.Test.Federation.PartnerChurch
  end
end
