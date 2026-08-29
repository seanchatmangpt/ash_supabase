defmodule AshSupabase.ChicagoTest05WelcomeTest do
  @moduledoc """
  PRD v26.8.29 Chicago Test 5 -- Welcome threshold crossing, exercised
  against `AshSupabase.Test.Welcome` and the generic
  `AshSupabase.Test.Obligations.Obligation` grammar, all through real
  Postgres.

  Proves two things:

    1. `Welcome.cross_threshold/3` durably records the welcome
       obligation, end to end (a real `:welcome` Obligation row, real
       `:owner_assigned` -> `:completed` transition, a matching
       Receipt row) rather than only returning an in-memory struct.
    2. `Welcome.security_stage_allowed?/1` -- the gate the PRD requires
       -- is `false` before the welcome obligation is satisfied and
       `true` only once it is `:completed`.
  """

  use AshSupabase.DataCase, async: true

  alias AshSupabase.Test.Obligations.Obligation
  alias AshSupabase.Test.Receipts.Receipt
  alias AshSupabase.Test.Welcome

  describe "cross_threshold/3 + security_stage_allowed?/1" do
    test "the security stage gate flips from false to true only once welcome is completed" do
      subject_id = Ash.UUID.generate()
      owner_id = Ash.UUID.generate()
      request_id = Ash.UUID.generate()

      refute Welcome.security_stage_allowed?(subject_id)

      assert {:ok, obligation, receipt} =
               Welcome.cross_threshold(subject_id, request_id, owner_id)

      assert obligation.kind == :welcome
      assert obligation.subject_id == subject_id
      assert obligation.owner_id == owner_id
      assert obligation.status == :completed
      assert obligation.outcome_label == "GREETED"

      assert receipt.subject_type == "Obligation"
      assert receipt.subject_id == obligation.id
      assert receipt.request_id == request_id
      assert receipt.process == "AshSupabase.Test.Welcome.cross_threshold"
      assert receipt.admission == :admitted
      assert receipt.outcome == :success
      assert receipt.ontology_version == AshSupabase.Test.Ontology.version()

      assert Welcome.security_stage_allowed?(subject_id)

      # Real persisted state, not just the returned struct.
      persisted_obligation = Ash.get!(Obligation, obligation.id, actor: :system)
      assert persisted_obligation.status == :completed
      assert persisted_obligation.owner_id == owner_id

      [persisted_receipt] = Receipt.for_subject!("Obligation", obligation.id)
      assert persisted_receipt.id == receipt.id
      assert persisted_receipt.request_id == request_id
    end

    test "an unrelated subject's welcome state is unaffected" do
      subject_id = Ash.UUID.generate()
      other_subject_id = Ash.UUID.generate()
      owner_id = Ash.UUID.generate()
      request_id = Ash.UUID.generate()

      assert {:ok, _obligation, _receipt} =
               Welcome.cross_threshold(subject_id, request_id, owner_id)

      assert Welcome.security_stage_allowed?(subject_id)
      refute Welcome.security_stage_allowed?(other_subject_id)
    end
  end
end
