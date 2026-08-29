defmodule AshSupabase.ChicagoTest13NotificationAfterCommitTest do
  @moduledoc """
  PRD v26.8.29 §5.5 "Notification ⇒ CommittedConsequence" / Chicago Test
  13 -- "Notification Only After Commit". This project's durable,
  DB-provable stand-in for "a notification was released" is a `Receipt`
  row: per §38, a receipt is written *inside* the same
  `Ash.DataLayer.transaction/5` call as the consequence it describes (see
  `AshSupabase.Ledger.Transfer`'s `transaction :post_transfer` block), so
  a receipt existing for a given attempt is direct evidence that
  attempt's whole transaction actually committed.

  This test proves both halves of that invariant against a real reactor
  and real Postgres:

    1. A transfer that opens its transaction (i.e. `verify_balanced` --
       the pure, DB-free preflight check -- already passed) but then
       fails to *resolve* one of the two accounts (a `debit_account_id`
       that is a syntactically valid UUID backed by no row at all)
       leaves **zero** `Receipt` rows behind. No notification without a
       commit.
    2. A transfer that succeeds end to end leaves **exactly one** new
       `Receipt` row, with `outcome: :success`. A real commit really does
       produce its receipt.
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

  describe "a transaction that fails partway through leaves no receipt" do
    test "a nonexistent debit_account_id fails the transaction after verify_balanced passes, committing nothing" do
      admin = create_admin!()
      credit_account = open_account!(admin, %{name: "Member Balance", kind: :liability})

      receipts_before = Repo.aggregate(Receipt, :count)

      assert {:error, _reason} =
               Reactor.run(Transfer, %{
                 # A syntactically valid UUID, backed by no `Account` row
                 # at all. debit_amount_cents == credit_amount_cents, so
                 # the pure, in-memory `verify_balanced` step genuinely
                 # passes and the transaction genuinely opens -- this
                 # fails while *resolving accounts inside the
                 # transaction*, after that preflight, not before it.
                 debit_account_id: Ash.UUID.generate(),
                 credit_account_id: credit_account.id,
                 debit_amount_cents: 10_000,
                 credit_amount_cents: 10_000,
                 memo: "should fail after verify_balanced, before any posting",
                 actor: admin,
                 request_id: Ash.UUID.generate()
               })

      # The direct proof: no receipt was committed for this failed
      # attempt -- a receipt (this project's durable stand-in for "the
      # notification was released") never exists unless the whole
      # transaction actually committed.
      assert Repo.aggregate(Receipt, :count) == receipts_before

      # And the one leg that *did* resolve to a real account never got
      # posted either -- the transaction rolled back as a whole, not
      # partially.
      assert Ash.get!(Account, credit_account.id, actor: admin).balance_cents == 0
    end
  end

  describe "a transaction that commits produces exactly one receipt" do
    test "a valid, balanced transfer between two fresh accounts commits and receipts exactly once" do
      admin = create_admin!()

      debit_account = open_account!(admin, %{name: "Funding", kind: :expense})
      credit_account = open_account!(admin, %{name: "Member Balance", kind: :liability})

      receipts_before = Repo.aggregate(Receipt, :count)
      request_id = Ash.UUID.generate()

      assert {:ok, receipt} =
               Reactor.run(Transfer, %{
                 debit_account_id: debit_account.id,
                 credit_account_id: credit_account.id,
                 debit_amount_cents: 5_000,
                 credit_amount_cents: 5_000,
                 memo: "real commit",
                 actor: admin,
                 request_id: request_id
               })

      assert Repo.aggregate(Receipt, :count) == receipts_before + 1

      [persisted] = Receipt.for_subject!("AshSupabase.Ledger.Transfer", receipt.subject_id)
      assert persisted.id == receipt.id
      assert persisted.request_id == request_id
      assert persisted.outcome == :success
      assert persisted.admission == :admitted

      assert Ash.get!(Account, debit_account.id, actor: admin).balance_cents == -5_000
      assert Ash.get!(Account, credit_account.id, actor: admin).balance_cents == 5_000
    end
  end
end
