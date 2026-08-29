defmodule AshSupabase.ChicagoTest11CareTest do
  @moduledoc """
  PRD v26.8.29 Chicago Test 11 -- Care, exercised against
  `AshSupabase.Test.Care.handle_request/3` and real Postgres.

  Proves the PRD's explicit invariant: "No care request may become
  ownerless without an explicit `BLOCKED:<reason>` state" -- a `nil`
  `owner_id` must never leave the obligation silently `:open`; it must
  close `:blocked`, with a reason, and the receipt must record
  `admission: :blocked, refusal_type: "NO_OWNER"`.
  """

  use AshSupabase.DataCase, async: true

  alias AshSupabase.Test.Care
  alias AshSupabase.Test.Obligations.Obligation

  describe "handle_request/3 -- a lawful owner is available" do
    test "the obligation is assigned, then closed completed/SERVICED" do
      subject_id = Ash.UUID.generate()
      owner_id = Ash.UUID.generate()
      request_id = Ash.UUID.generate()

      assert {:ok, obligation, receipt} = Care.handle_request(subject_id, request_id, owner_id)

      assert obligation.kind == :care
      assert obligation.subject_id == subject_id
      assert obligation.owner_id == owner_id
      assert obligation.status == :completed
      assert obligation.outcome_label == "SERVICED"
      assert obligation.blocked_reason == nil

      assert receipt.subject_type == "Obligation"
      assert receipt.subject_id == obligation.id
      assert receipt.request_id == request_id
      assert receipt.process == "AshSupabase.Test.Care.handle_request"
      assert receipt.admission == :admitted
      assert receipt.outcome == :success
      assert receipt.refusal_type == nil

      persisted = Ash.get!(Obligation, obligation.id, actor: :system)
      assert persisted.status == :completed
      assert persisted.owner_id == owner_id
    end
  end

  describe "handle_request/3 -- no lawful owner available" do
    test "the obligation closes BLOCKED:no_owner instead of staying silently open" do
      subject_id = Ash.UUID.generate()
      request_id = Ash.UUID.generate()

      assert {:ok, obligation, receipt} = Care.handle_request(subject_id, request_id, nil)

      assert obligation.kind == :care
      assert obligation.subject_id == subject_id
      assert obligation.owner_id == nil
      assert obligation.status == :blocked
      assert obligation.blocked_reason == "no lawful owner available"
      assert obligation.outcome_label == nil

      assert receipt.subject_type == "Obligation"
      assert receipt.subject_id == obligation.id
      assert receipt.request_id == request_id
      assert receipt.process == "AshSupabase.Test.Care.handle_request"
      assert receipt.admission == :blocked
      assert receipt.outcome == :blocked
      assert receipt.refusal_type == "NO_OWNER"

      # The obligation's terminal state is real, persisted, and typed
      # -- never left as :open.
      persisted = Ash.get!(Obligation, obligation.id, actor: :system)
      assert persisted.status == :blocked
      refute persisted.status == :open
      assert persisted.blocked_reason == "no lawful owner available"
    end
  end
end
