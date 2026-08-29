defmodule AshSupabase.ChicagoTest02To04FinanceTest do
  @moduledoc """
  PRD v26.8.29 Chicago Tests 2 ("Admin Credits Member Funds"), 3
  ("Unauthorized Financial Credit"), and 4 / 20 ("Invalid Double-Entry
  Construction") -- exercised against `AshSupabase.Ledger.Transfer`, a
  real `Ash.Reactor`, and real Postgres.
  """

  use AshSupabase.DataCase, async: true

  alias AshSupabase.Ledger.Transfer
  alias AshSupabase.Test.Finance.Account
  alias AshSupabase.Test.Receipts.Receipt

  defp open_account!(actor, attrs) do
    Account
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!()
  end

  describe "Chicago Test 2 -- Admin Credits Member Funds" do
    test "a $100 admin credit balances, commits, and receipts" do
      admin = create_admin!()
      member = create_user!()

      funding = open_account!(admin, %{name: "Funding", kind: :expense})

      member_liability =
        open_account!(admin, %{name: "Member Balance", kind: :liability, owner_id: member.id})

      request_id = Ash.UUID.generate()

      assert {:ok, receipt} =
               Reactor.run(Transfer, %{
                 debit_account_id: funding.id,
                 credit_account_id: member_liability.id,
                 debit_amount_cents: 10_000,
                 credit_amount_cents: 10_000,
                 memo: "Admin credit",
                 actor: admin,
                 request_id: request_id
               })

      assert receipt.outcome == :success
      assert receipt.admission == :admitted
      assert receipt.financial_postings |> Enum.map(& &1["amount_cents"]) == [10_000, 10_000]

      member_liability = Ash.get!(Account, member_liability.id, actor: admin)
      funding = Ash.get!(Account, funding.id, actor: admin)

      assert member_liability.balance_cents == 10_000
      assert funding.balance_cents == -10_000

      funding_events =
        AshSupabase.Test.Events.Event
        |> Ash.Query.for_read(:for_record, %{record_id: funding.id})
        |> Ash.read!()

      member_events =
        AshSupabase.Test.Events.Event
        |> Ash.Query.for_read(:for_record, %{record_id: member_liability.id})
        |> Ash.read!()

      # Each account's own dual-table event log has its :create event plus
      # exactly one posting event -- the transfer's two legs, independently
      # append-only-logged per PRD's dual-table pattern.
      assert Enum.map(funding_events, & &1.action) == [:create, :post_debit]
      assert Enum.map(member_events, & &1.action) == [:create, :post_credit]

      [persisted_receipt] =
        Receipt.for_subject!("AshSupabase.Ledger.Transfer", receipt.subject_id)

      assert persisted_receipt.id == receipt.id
      assert persisted_receipt.request_id == request_id
    end
  end

  describe "Chicago Test 3 -- Unauthorized Financial Credit" do
    test "a non-admin actor is refused before either leg is posted" do
      admin = create_admin!()
      non_admin = create_user!()

      funding = open_account!(admin, %{name: "Funding", kind: :expense})

      member_liability =
        open_account!(admin, %{name: "Member Balance", kind: :liability, owner_id: non_admin.id})

      receipts_before = Repo.aggregate(Receipt, :count)

      assert {:error, _reason} =
               Reactor.run(Transfer, %{
                 debit_account_id: funding.id,
                 credit_account_id: member_liability.id,
                 debit_amount_cents: 10_000,
                 credit_amount_cents: 10_000,
                 memo: "should be refused",
                 actor: non_admin,
                 request_id: Ash.UUID.generate()
               })

      # Zero partial financial consequence (PRD 5.2/5.3): reload and prove
      # neither leg moved and no receipt was written for this attempt.
      funding = Ash.get!(Account, funding.id, actor: admin)
      member_liability = Ash.get!(Account, member_liability.id, actor: admin)

      assert funding.balance_cents == 0
      assert member_liability.balance_cents == 0
      assert Repo.aggregate(Receipt, :count) == receipts_before
    end
  end

  describe "Chicago Test 4/20 -- Invalid Double-Entry Construction" do
    test "an unbalanced transfer is refused before any database transaction opens" do
      admin = create_admin!()

      funding = open_account!(admin, %{name: "Funding", kind: :expense})
      liability = open_account!(admin, %{name: "Member Balance", kind: :liability})

      assert {:error, reason} =
               Reactor.run(Transfer, %{
                 debit_account_id: funding.id,
                 credit_account_id: liability.id,
                 # Debit $100, Credit $90 -- exactly PRD section 20's example.
                 debit_amount_cents: 10_000,
                 credit_amount_cents: 9_000,
                 memo: "unbalanced",
                 actor: admin,
                 request_id: Ash.UUID.generate()
               })

      assert inspect(reason) =~ "financial_invariant"

      funding = Ash.get!(Account, funding.id, actor: admin)
      liability = Ash.get!(Account, liability.id, actor: admin)

      assert funding.balance_cents == 0
      assert liability.balance_cents == 0
    end
  end
end
