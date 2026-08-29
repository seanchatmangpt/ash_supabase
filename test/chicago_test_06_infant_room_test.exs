defmodule AshSupabase.ChicagoTest06InfantRoomTest do
  @moduledoc """
  PRD v26.8.29 Chicago Test 6 -- the Infant Room decision, durably
  recorded by `AshSupabase.Test.Welcome.inform_parent_room/3` as a
  closed `:infant_room` Obligation, exercised against real Postgres.

  `inform_parent_room/3` does not decide anything itself (the Welcome
  Team's own deterministic, rule-based workflow already decided
  upstream) -- its only job is to make that decision durable. Every one
  of the four decision atoms must produce a real Obligation row that
  reaches a closed status, per §27's "No obligation may silently
  disappear" -- including `:not_applicable`, which is the case most at
  risk of being treated as "nothing to record".
  """

  use AshSupabase.DataCase, async: true

  alias AshSupabase.Test.Obligations.Obligation
  alias AshSupabase.Test.Receipts.Receipt
  alias AshSupabase.Test.Welcome

  @closed_statuses [:completed, :declined, :blocked]

  describe "inform_parent_room/3" do
    test "an :informed decision is recorded as a completed obligation labeled INFORMED" do
      assert_recorded(:informed, "INFORMED")
    end

    test "a :declined decision is still recorded as a completed obligation, labeled DECLINED" do
      assert_recorded(:declined, "DECLINED")
    end

    test "a :routed decision is recorded as a completed obligation labeled ROUTED" do
      assert_recorded(:routed, "ROUTED")
    end

    test ":not_applicable is not silently skipped -- it is still a real, closed obligation" do
      assert_recorded(:not_applicable, "NOT_APPLICABLE")
    end

    test "each call creates its own obligation and receipt -- nothing is overwritten or reused" do
      subject_id = Ash.UUID.generate()

      assert {:ok, first_obligation, first_receipt} =
               Welcome.inform_parent_room(subject_id, Ash.UUID.generate(), :informed)

      assert {:ok, second_obligation, second_receipt} =
               Welcome.inform_parent_room(subject_id, Ash.UUID.generate(), :not_applicable)

      refute first_obligation.id == second_obligation.id
      refute first_receipt.id == second_receipt.id

      persisted =
        Obligation.for_subject_and_kind!(subject_id, :infant_room, actor: :system)

      assert length(persisted) == 2
      assert Enum.all?(persisted, &(&1.status in @closed_statuses))
    end
  end

  defp assert_recorded(decision, expected_label) do
    subject_id = Ash.UUID.generate()
    request_id = Ash.UUID.generate()

    obligations_before = Repo.aggregate(Obligation, :count)

    assert {:ok, obligation, receipt} =
             Welcome.inform_parent_room(subject_id, request_id, decision)

    # A real obligation was created -- never a silent no-op.
    assert Repo.aggregate(Obligation, :count) == obligations_before + 1

    assert obligation.kind == :infant_room
    assert obligation.subject_id == subject_id
    assert obligation.status == :completed
    assert obligation.status in @closed_statuses
    assert obligation.outcome_label == expected_label

    assert receipt.subject_type == "Obligation"
    assert receipt.subject_id == obligation.id
    assert receipt.request_id == request_id
    assert receipt.process == "AshSupabase.Test.Welcome.inform_parent_room"
    assert receipt.admission == :admitted
    assert receipt.outcome == :success
    assert receipt.metadata["decision"] == to_string(decision)

    # Real persisted rows, not just the returned structs.
    persisted_obligation = Ash.get!(Obligation, obligation.id, actor: :system)
    assert persisted_obligation.status == :completed
    assert persisted_obligation.outcome_label == expected_label

    [persisted_receipt] = Receipt.for_subject!("Obligation", obligation.id)
    assert persisted_receipt.id == receipt.id
  end
end
