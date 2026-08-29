defmodule AshSupabase.Test.Care do
  @moduledoc """
  The Care scenario (PRD v26.8.29 §27), instantiating the generic
  obligation grammar:

      Threshold -> Signal -> Classification -> Owner -> Obligation
        -> Action -> Receipt -> NextState

  The PRD is explicit that "no care request may become ownerless
  without an explicit `BLOCKED:<reason>` state" -- `handle_request/3`
  is written so that is structurally true: when no lawful owner is
  available, the obligation is *not* left `:open` (which would be a
  silent disappearance under §27), it is closed `:blocked` with a
  reason, and the receipt records `admission: :blocked,
  refusal_type: "NO_OWNER"`.
  """

  alias AshSupabase.Test.Obligations.Obligation
  alias AshSupabase.Test.Ontology
  alias AshSupabase.Test.Receipts.Receipt
  alias AshSupabase.Test.Repo

  @system_actor :system

  @doc """
  Chicago Test 11. Opens a `:care` obligation for `subject_id`.

    * `owner_id` present -- assigns it, then closes the obligation
      `:completed` with `outcome_label: "SERVICED"`.
    * `owner_id` nil -- closes the obligation `:blocked` instead, with
      `blocked_reason: "no lawful owner available"`, and the receipt is
      written with `admission: :blocked, outcome: :blocked,
      refusal_type: "NO_OWNER"`.

  Both branches run inside one transaction and both produce a receipt
  -- the obligation always reaches a closed, typed state.
  """
  def handle_request(subject_id, request_id, owner_id) do
    AshSupabase.Transaction.run(Repo, fn ->
      obligation =
        Obligation.create!(%{kind: :care, subject_id: subject_id}, actor: @system_actor)

      if is_nil(owner_id) do
        obligation =
          Obligation.block!(
            obligation,
            %{blocked_reason: "no lawful owner available"},
            actor: @system_actor
          )

        receipt =
          Receipt.create!(
            %{
              subject_type: "Obligation",
              subject_id: to_string(obligation.id),
              ontology_version: Ontology.version(),
              request_id: request_id,
              process: "AshSupabase.Test.Care.handle_request",
              admission: :blocked,
              outcome: :blocked,
              refusal_type: "NO_OWNER",
              metadata: %{subject_id: to_string(subject_id)}
            },
            actor: @system_actor
          )

        {obligation, receipt}
      else
        obligation =
          Obligation.assign_owner!(obligation, %{owner_id: owner_id}, actor: @system_actor)

        obligation =
          Obligation.complete!(obligation, %{outcome_label: "SERVICED"}, actor: @system_actor)

        receipt =
          Receipt.create!(
            %{
              subject_type: "Obligation",
              subject_id: to_string(obligation.id),
              ontology_version: Ontology.version(),
              request_id: request_id,
              process: "AshSupabase.Test.Care.handle_request",
              admission: :admitted,
              outcome: :success,
              metadata: %{subject_id: to_string(subject_id), owner_id: to_string(owner_id)}
            },
            actor: @system_actor
          )

        {obligation, receipt}
      end
    end)
    |> case do
      {:ok, {obligation, receipt}} -> {:ok, obligation, receipt}
    end
  end
end
