defmodule AshSupabase.Test.Recovery do
  @moduledoc """
  The Recovery scenario (PRD v26.8.29 §27), instantiating the generic
  obligation grammar:

      Threshold -> Signal -> Classification -> Owner -> Obligation
        -> Action -> Receipt -> NextState

  Mirrors `AshSupabase.Test.Care.handle_request/3`'s grammar exactly
  (kind `:recovery` instead of `:care`, `outcome_label: "HANDED_OFF"`
  instead of `"SERVICED"`) -- the same "no request may become
  ownerless without an explicit `BLOCKED:<reason>` state" invariant
  applies here too: a nil `owner_id` closes the obligation `:blocked`,
  never leaves it silently `:open`.
  """

  alias AshSupabase.Test.Obligations.Obligation
  alias AshSupabase.Test.Ontology
  alias AshSupabase.Test.Receipts.Receipt
  alias AshSupabase.Test.Repo

  @system_actor :system

  @doc """
  Chicago Test 12. Opens a `:recovery` obligation for `subject_id`.

    * `owner_id` present -- assigns it, then closes the obligation
      `:completed` with `outcome_label: "HANDED_OFF"`.
    * `owner_id` nil -- closes the obligation `:blocked` instead, with
      `blocked_reason: "no lawful owner available"`, and the receipt is
      written with `admission: :blocked, outcome: :blocked,
      refusal_type: "NO_OWNER"`.
  """
  def route(subject_id, request_id, owner_id) do
    AshSupabase.Transaction.run(Repo, fn ->
      obligation =
        Obligation.create!(%{kind: :recovery, subject_id: subject_id}, actor: @system_actor)

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
              process: "AshSupabase.Test.Recovery.route",
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
          Obligation.complete!(obligation, %{outcome_label: "HANDED_OFF"}, actor: @system_actor)

        receipt =
          Receipt.create!(
            %{
              subject_type: "Obligation",
              subject_id: to_string(obligation.id),
              ontology_version: Ontology.version(),
              request_id: request_id,
              process: "AshSupabase.Test.Recovery.route",
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
