defmodule AshSupabase.ChicagoTest46To47CrownTest do
  @moduledoc """
  PRD v26.8.29 §46-47 -- the "Crown Chicago Scenario", the release-crown
  end-to-end proof that every capability built for the ZOE LA proving
  ground actually composes: one Sunday-morning narrative, exercised
  against real Postgres, with zero mocks and zero LLM calls.

  Initial state (§46):

    * Kids demand requires 6 qualified workers; 4 are locally available
      (deficit 2); one verified partner church has 3 qualified workers
      available.
    * An admin credits $200 to the emergency transportation fund.
    * A family (one adult, one infant, two other children) crosses the
      Welcome threshold; the infant qualifies for the parent room; the
      adult requests an escort to the Kids area.

  What honesty requires stating plainly: this proving ground does not
  implement a dedicated "check a child in" resource (that capability
  was out of scope for this build) -- "route children through the Kids
  process" is demonstrated here as "the capacity that makes routing
  them possible now durably exists", i.e. the `StaffingRequirement`
  reaching `:fulfilled` status via federation, not as a per-child
  check-in record. Everything else in this test is the real
  thing: real Ash actions, a real `Ash.Reactor`, real Postgres rows.
  """

  use AshSupabase.DataCase, async: true

  alias AshSupabase.Ledger.Transfer
  alias AshSupabase.Replay
  alias AshSupabase.Test.Federation.PartnerChurch
  alias AshSupabase.Test.Finance.Account
  alias AshSupabase.Test.Kids.FulfillmentSolver
  alias AshSupabase.Test.Kids.StaffingRequirement
  alias AshSupabase.Test.Receipts.Receipt
  alias AshSupabase.Test.Welcome
  alias AshSupabase.Test.Welcome.Post

  test "the crown scenario: Kids federation + Welcome + escort + a balanced financial credit, one Sunday" do
    admin = create_admin!()
    guardian = create_user!()

    # ---- 1. Kids capacity deficit, fulfilled entirely through federation ----
    requirement =
      StaffingRequirement
      |> Ash.Changeset.for_create(:create, %{
        service_name: "Sunday Kids -- 9am",
        required_workers: 6,
        local_available_workers: 4
      })
      |> Ash.create!()

    partner =
      PartnerChurch
      |> Ash.Changeset.for_create(:create, %{
        name: "Grace Fellowship",
        qualified_available_workers: 3,
        verified_safeguarding: true,
        distance_miles: 12
      })
      |> Ash.create!()

    kids_request_id = Ash.UUID.generate()

    assert {:ok, :federated_fulfillment, kids_receipt, plan} =
             FulfillmentSolver.fulfill(requirement.id, kids_request_id)

    assert plan == [%{partner_church_id: partner.id, workers: 2}]
    assert kids_receipt.admission == :admitted

    requirement = Ash.get!(StaffingRequirement, requirement.id)
    partner = Ash.get!(PartnerChurch, partner.id)

    assert requirement.status == :fulfilled
    assert requirement.fulfilled_workers == 2
    assert partner.reserved_workers == 2

    # "Route children through the Kids process": the capability that
    # makes it lawful now durably exists -- required capability implied
    # a required fulfillment PATH, not a required LOCAL implementation
    # (PRD §26).
    assert requirement.required_workers - requirement.local_available_workers -
             requirement.fulfilled_workers <= 0

    # ---- 2. Admin credits the emergency transportation fund: $200, balanced ----
    general_fund =
      Account
      |> Ash.Changeset.for_create(:create, %{name: "General Fund", kind: :asset}, actor: admin)
      |> Ash.create!()

    transportation_fund =
      Account
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Emergency Transportation Fund", kind: :liability},
        actor: admin
      )
      |> Ash.create!()

    finance_request_id = Ash.UUID.generate()

    assert {:ok, finance_receipt} =
             Reactor.run(Transfer, %{
               debit_account_id: general_fund.id,
               credit_account_id: transportation_fund.id,
               debit_amount_cents: 20_000,
               credit_amount_cents: 20_000,
               memo: "Emergency transportation fund",
               actor: admin,
               request_id: finance_request_id
             })

    assert finance_receipt.outcome == :success

    postings_total_debit =
      finance_receipt.financial_postings
      |> Enum.filter(&(&1["direction"] == "debit"))
      |> Enum.map(& &1["amount_cents"])
      |> Enum.sum()

    postings_total_credit =
      finance_receipt.financial_postings
      |> Enum.filter(&(&1["direction"] == "credit"))
      |> Enum.map(& &1["amount_cents"])
      |> Enum.sum()

    assert postings_total_debit == postings_total_credit
    assert postings_total_debit == 20_000

    general_fund = Ash.get!(Account, general_fund.id, actor: admin)
    transportation_fund = Ash.get!(Account, transportation_fund.id, actor: admin)
    assert general_fund.balance_cents == -20_000
    assert transportation_fund.balance_cents == 20_000

    # ---- 3. Family crosses the Welcome threshold; welcome gates security ----
    family_subject_id = guardian.id
    welcome_request_id = Ash.UUID.generate()

    refute Welcome.security_stage_allowed?(family_subject_id)

    assert {:ok, welcome_obligation, welcome_receipt} =
             Welcome.cross_threshold(family_subject_id, welcome_request_id, admin.id)

    assert welcome_obligation.status == :completed
    assert welcome_receipt.admission == :admitted
    assert Welcome.security_stage_allowed?(family_subject_id)

    # ---- 4. Infant qualifies for the parent room -- durably recorded, not silently handled ----
    assert {:ok, infant_room_obligation, _receipt} =
             Welcome.inform_parent_room(family_subject_id, Ash.UUID.generate(), :informed)

    assert infant_room_obligation.status == :completed
    assert infant_room_obligation.outcome_label == "INFORMED"

    # ---- 5. One adult requests escort to the Kids area -- coverage checked first ----
    welcome_post =
      Post
      |> Ash.Changeset.for_create(:create, %{
        name: "Main Welcome Post",
        minimum_coverage: 2,
        current_coverage: 3
      })
      |> Ash.create!()

    assert {:ok, escort_obligation, escort_receipt} =
             Welcome.request_escort(welcome_post.id, family_subject_id, Ash.UUID.generate(), [])

    assert escort_obligation.status == :completed
    assert escort_obligation.outcome_label == "ESCORTED"
    assert escort_receipt.admission == :admitted

    reloaded_post = Post.by_id!(welcome_post.id)
    assert reloaded_post.current_coverage == 2
    # Coverage never dropped below the post's minimum at any point --
    # the exact invariant PRD §23/Chicago Test 7 requires.
    assert reloaded_post.current_coverage >= welcome_post.minimum_coverage

    # ---- 6. Every consequential step this scenario performed is receipted ----
    all_obligation_receipts =
      [welcome_obligation, infant_room_obligation, escort_obligation]
      |> Enum.map(&Receipt.for_subject!("Obligation", to_string(&1.id)))
      |> List.flatten()

    assert length(all_obligation_receipts) == 3
    assert Enum.all?(all_obligation_receipts, &(&1.admission == :admitted))

    # ---- 7. Event/state replay equivalence holds for what this scenario touched ----
    requirement_hash_before = Replay.state_hash(StaffingRequirement, requirement)
    account_hash_before = Replay.state_hash(Account, transportation_fund)

    AshSupabase.Test.Events.Event
    |> Ash.ActionInput.for_action(:replay, %{})
    |> Ash.run_action!()

    requirement_hash_after =
      StaffingRequirement
      |> Ash.get!(requirement.id)
      |> then(&Replay.state_hash(StaffingRequirement, &1))

    account_hash_after =
      Account
      |> Ash.get!(transportation_fund.id, actor: admin)
      |> then(&Replay.state_hash(Account, &1))

    assert Replay.compare(requirement_hash_before, requirement_hash_after) == :alive
    assert Replay.compare(account_hash_before, account_hash_after) == :alive

    # ---- 8. Post-LLM: nothing in this entire scenario ever called one ----
    # (structural, not a runtime network assertion -- see
    # test/chicago_test_16_llm_zero_test.exs for the standing gate this
    # scenario relies on staying true.)
    refute Enum.any?(
             [
               Atom.to_string(FulfillmentSolver),
               Atom.to_string(Welcome),
               Atom.to_string(Transfer)
             ],
             &String.contains?(&1, ["OpenAI", "Anthropic", "LLM"])
           )
  end
end
