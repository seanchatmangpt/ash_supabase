defmodule AshSupabase.ChicagoTest07EscortTest do
  @moduledoc """
  PRD v26.8.29 Chicago Test 7 -- Escort/Coverage, PRD §23's
  `Coverage(W,t)` invariant, exercised against
  `AshSupabase.Test.Welcome.request_escort/4` and real Postgres.

  Proves both halves of the invariant:

    * with slack (`current_coverage - 1 >= minimum_coverage`), an
      escort is granted and coverage actually drops by one;
    * without slack, an escort is refused with **zero writes** -- no
      Obligation row appears, no Receipt row appears, coverage is
      unchanged -- unless `replacement_reserved?: true` is explicitly
      passed, in which case it is granted anyway.
  """

  use AshSupabase.DataCase, async: true

  alias AshSupabase.Test.Obligations.Obligation
  alias AshSupabase.Test.Receipts.Receipt
  alias AshSupabase.Test.Welcome
  alias AshSupabase.Test.Welcome.Post

  describe "request_escort/4 -- with slack" do
    test "succeeds and coverage drops by exactly one" do
      # 3 - 1 = 2, which is still >= minimum_coverage (2) -- genuine
      # slack, unlike the exactly-at-minimum fixture below.
      post = Post.create!(%{name: "Main Entrance", minimum_coverage: 2, current_coverage: 3})
      subject_id = Ash.UUID.generate()
      request_id = Ash.UUID.generate()

      assert {:ok, obligation, receipt} =
               Welcome.request_escort(post.id, subject_id, request_id, [])

      assert obligation.kind == :escort
      assert obligation.subject_id == subject_id
      assert obligation.status == :completed
      assert obligation.outcome_label == "ESCORTED"

      assert receipt.process == "AshSupabase.Test.Welcome.request_escort"
      assert receipt.admission == :admitted
      assert receipt.outcome == :success

      assert Post.by_id!(post.id).current_coverage == 2
    end
  end

  describe "request_escort/4 -- no slack (current_coverage == minimum_coverage)" do
    test "without replacement_reserved? it is refused with zero writes" do
      post = Post.create!(%{name: "Tight Post", minimum_coverage: 2, current_coverage: 2})
      subject_id = Ash.UUID.generate()
      request_id = Ash.UUID.generate()

      obligations_before = Repo.aggregate(Obligation, :count)
      receipts_before = Repo.aggregate(Receipt, :count)

      assert {:error, {:blocked, :coverage, _reason}} =
               Welcome.request_escort(post.id, subject_id, request_id, [])

      # Zero writes: no obligation, no receipt, coverage untouched.
      assert Repo.aggregate(Obligation, :count) == obligations_before
      assert Repo.aggregate(Receipt, :count) == receipts_before
      assert Post.by_id!(post.id).current_coverage == 2
    end

    test "with replacement_reserved?: true it succeeds anyway" do
      post = Post.create!(%{name: "Tight Post", minimum_coverage: 2, current_coverage: 2})
      subject_id = Ash.UUID.generate()
      request_id = Ash.UUID.generate()

      assert {:ok, obligation, receipt} =
               Welcome.request_escort(post.id, subject_id, request_id,
                 replacement_reserved?: true
               )

      assert obligation.status == :completed
      assert obligation.outcome_label == "ESCORTED"
      assert receipt.admission == :admitted

      assert Post.by_id!(post.id).current_coverage == 1
    end
  end
end
