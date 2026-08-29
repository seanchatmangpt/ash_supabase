defmodule AshSupabase.ChicagoTest17DeterministicReplayTest do
  @moduledoc """
  PRD v26.8.29 Chicago Test 17 -- "Deterministic Replay": the same input
  must produce the same outcome, every time -- not merely "does not
  corrupt state", but "is provably reproducible". This is proven the safe
  way, against a refusal-shaped input rather than a real financial
  commit: given the identical *unbalanced* transfer construction twice in
  a row (same two real accounts, same amounts, only a fresh `request_id`
  each time -- `request_id` is not itself an input `verify_balanced`
  looks at), `AshSupabase.Ledger.Transfer` must:

    * refuse both times, with the same shaped `{:error, ...}` -- both at
      the top-level exception class Reactor wraps it in, and (drilling
      down to what actually failed) the exact same underlying refusal
      tuple, since that refusal is a pure function of the (identical)
      debit/credit amounts;
    * leave zero writes both times -- neither account's `balance_cents`
      moves, and no `Receipt` is ever committed for either attempt's
      `request_id`.
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

  test "the identical unbalanced construction refuses identically, twice, with zero writes both times" do
    admin = create_admin!()

    debit_account = open_account!(admin, %{name: "Funding", kind: :expense})
    credit_account = open_account!(admin, %{name: "Member Balance", kind: :liability})

    base_params = %{
      debit_account_id: debit_account.id,
      credit_account_id: credit_account.id,
      # Debit $100, Credit $90 -- exactly PRD section 20's example.
      debit_amount_cents: 10_000,
      credit_amount_cents: 9_000,
      memo: "unbalanced -- run twice for determinism",
      actor: admin
    }

    request_id_1 = Ash.UUID.generate()
    request_id_2 = Ash.UUID.generate()

    assert {:error, reason1} =
             Reactor.run(Transfer, Map.put(base_params, :request_id, request_id_1))

    assert {:error, reason2} =
             Reactor.run(Transfer, Map.put(base_params, :request_id, request_id_2))

    # Same shape at the top level Reactor wraps the failure in...
    assert reason1.__struct__ == reason2.__struct__

    # ...and, drilling into the actual `RunStepError` each wraps, the
    # exact same underlying refusal -- proving the *reason itself* is a
    # pure function of the (identical) amounts, not of the (different)
    # request_id or of anything else nondeterministic about the run.
    [underlying1] = Reactor.Error.find_errors(reason1, Reactor.Error.Invalid.RunStepError)
    [underlying2] = Reactor.Error.find_errors(reason2, Reactor.Error.Invalid.RunStepError)

    assert underlying1.step.name == underlying2.step.name
    assert underlying1.step.name == :verify_balanced
    assert underlying1.error == underlying2.error
    assert inspect(underlying1.error) =~ "financial_invariant"

    # Zero writes, both times: neither account ever moved off its
    # opening balance...
    assert Ash.get!(Account, debit_account.id, actor: admin).balance_cents == 0
    assert Ash.get!(Account, credit_account.id, actor: admin).balance_cents == 0

    # ...and no receipt exists for either attempt's request_id.
    receipts_for_these_attempts =
      Receipt
      |> Ash.read!()
      |> Enum.filter(&(&1.request_id in [request_id_1, request_id_2]))

    assert receipts_for_these_attempts == []
  end
end
