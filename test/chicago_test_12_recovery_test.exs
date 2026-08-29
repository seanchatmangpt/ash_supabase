defmodule AshSupabase.ChicagoTest12RecoveryTest do
  @moduledoc """
  PRD v26.8.29 Chicago Test 12 -- Recovery, exercised against
  `AshSupabase.Test.Recovery.route/3` and real Postgres.

  Mirrors Chicago Test 11 (Care) exactly: the same "no request may
  become ownerless without an explicit `BLOCKED:<reason>` state"
  invariant applies to Recovery too -- a `nil` `owner_id` must close
  the obligation `:blocked`, never leave it silently `:open`.
  """

  use AshSupabase.DataCase, async: true

  alias AshSupabase.Test.Obligations.Obligation
  alias AshSupabase.Test.Recovery

  describe "route/3 -- a lawful owner is available" do
    test "the obligation is assigned, then closed completed/HANDED_OFF" do
      subject_id = Ash.UUID.generate()
      owner_id = Ash.UUID.generate()
      request_id = Ash.UUID.generate()

      assert {:ok, obligation, receipt} = Recovery.route(subject_id, request_id, owner_id)

      assert obligation.kind == :recovery
      assert obligation.subject_id == subject_id
      assert obligation.owner_id == owner_id
      assert obligation.status == :completed
      assert obligation.outcome_label == "HANDED_OFF"
      assert obligation.blocked_reason == nil

      assert receipt.subject_type == "Obligation"
      assert receipt.subject_id == obligation.id
      assert receipt.request_id == request_id
      assert receipt.process == "AshSupabase.Test.Recovery.route"
      assert receipt.admission == :admitted
      assert receipt.outcome == :success
      assert receipt.refusal_type == nil

      persisted = Ash.get!(Obligation, obligation.id, actor: :system)
      assert persisted.status == :completed
      assert persisted.owner_id == owner_id
    end
  end

  describe "route/3 -- no lawful owner available" do
    test "the obligation closes BLOCKED:no_owner instead of staying silently open" do
      subject_id = Ash.UUID.generate()
      request_id = Ash.UUID.generate()

      assert {:ok, obligation, receipt} = Recovery.route(subject_id, request_id, nil)

      assert obligation.kind == :recovery
      assert obligation.subject_id == subject_id
      assert obligation.owner_id == nil
      assert obligation.status == :blocked
      assert obligation.blocked_reason == "no lawful owner available"
      assert obligation.outcome_label == nil

      assert receipt.subject_type == "Obligation"
      assert receipt.subject_id == obligation.id
      assert receipt.request_id == request_id
      assert receipt.process == "AshSupabase.Test.Recovery.route"
      assert receipt.admission == :blocked
      assert receipt.outcome == :blocked
      assert receipt.refusal_type == "NO_OWNER"

      persisted = Ash.get!(Obligation, obligation.id, actor: :system)
      assert persisted.status == :blocked
      refute persisted.status == :open
      assert persisted.blocked_reason == "no lawful owner available"
    end
  end
end
