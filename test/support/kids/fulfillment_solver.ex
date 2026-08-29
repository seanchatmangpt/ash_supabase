defmodule AshSupabase.Test.Kids.FulfillmentSolver do
  @moduledoc """
  Kids capacity + federation: the architectural crown capability (PRD
  v26.8.29 §25-26).

  When a `AshSupabase.Test.Kids.StaffingRequirement`'s local capacity is
  less than what is required, this module deterministically searches a
  closed graph of lawful fulfillment candidates -- today that graph is
  just `AshSupabase.Test.Federation.PartnerChurch`, nearest
  verified-safeguarding partner first -- and either commits a
  fulfillment path or produces a receipted, typed
  `BLOCKED:CAPABILITY_CAPACITY` result. There is no scoring/optimization
  step beyond the fixed candidate order: the solver may optimize *over*
  the admitted graph, but it may never invent a capability (e.g. draw
  from an unverified partner) that isn't already admitted into it.

  Every call to `fulfill/2` ends in exactly one receipted, terminal
  outcome:

    * `{:ok, :no_deficit, receipt}` -- local capacity already covers the
      requirement; nothing to federate.
    * `{:ok, :federated_fulfillment, receipt, fulfillment_plan}` -- the
      full deficit was covered by one or more verified partner
      churches; every reservation, the requirement's fulfillment, and
      the receipt commit atomically in one transaction.
    * `{:error, {:blocked, :capability_capacity, receipt}}` -- even
      after walking every verified candidate, the deficit could not be
      fully covered. No partial/inconsistent reservation is ever
      committed on this path (all-or-nothing): the only writes are
      marking the requirement `:blocked` and the receipt itself, which
      makes the refusal a durable, typed fact rather than a silent
      no-op.
  """

  alias AshSupabase.Test.Federation.PartnerChurch
  alias AshSupabase.Test.Kids.StaffingRequirement
  alias AshSupabase.Test.Ontology
  alias AshSupabase.Test.Receipts.Receipt
  alias AshSupabase.Test.Repo

  @process "AshSupabase.Test.Kids.FulfillmentSolver.fulfill"
  @subject_type "KidsStaffingRequirement"

  @doc """
  Fulfill `requirement_id`'s deficit (if any), tagging every write and
  the resulting receipt with `request_id` (a correlation id for this
  specific attempt).
  """
  def fulfill(requirement_id, request_id) do
    requirement = Ash.get!(StaffingRequirement, requirement_id)
    deficit = requirement.required_workers - requirement.local_available_workers

    if deficit <= 0 do
      fulfill_locally(requirement, request_id)
    else
      candidates = verified_candidates()
      {plan, remaining} = build_plan(candidates, deficit)

      if remaining == 0 do
        commit_federated_fulfillment(requirement, deficit, plan, request_id)
      else
        # `deficit - remaining` is exactly the sum of everything that
        # *was* available across every verified candidate: the greedy
        # walk below never leaves capacity on the table before it runs
        # out of candidates, so if it still couldn't zero out
        # `remaining`, this is the true ceiling of what federation could
        # offer.
        best_available = deficit - remaining
        block(requirement, deficit, best_available, request_id)
      end
    end
  end

  # Reads verified-safeguarding candidates nearest-first via the
  # `:candidates` read action, then re-checks the hard safeguarding
  # constraint ourselves -- the solver must never draw from an
  # unverified partner even if the read action's filter is ever
  # changed or bypassed.
  defp verified_candidates do
    PartnerChurch
    |> Ash.Query.for_read(:candidates, %{})
    |> Ash.read!()
    |> Enum.filter(&(&1.verified_safeguarding == true))
  end

  # Greedily reserves min(available, remaining deficit) from each
  # candidate in order until the deficit is covered or candidates are
  # exhausted. This fixed nearest-verified-first order *is* the
  # deterministic solver -- there is no additional scoring/optimization.
  # Returns `{fulfillment_plan, remaining_deficit}`; `remaining_deficit`
  # is `0` iff the plan fully covers the original deficit.
  defp build_plan(candidates, deficit) do
    {plan, remaining} =
      Enum.reduce(candidates, {[], deficit}, fn candidate, {plan, remaining} ->
        cond do
          remaining <= 0 ->
            {plan, remaining}

          # Belt-and-braces: never draw from an unverified candidate,
          # even though `verified_candidates/0` already filtered them.
          candidate.verified_safeguarding != true ->
            {plan, remaining}

          true ->
            available = max(candidate.qualified_available_workers - candidate.reserved_workers, 0)
            take = min(available, remaining)

            if take > 0 do
              {[%{partner_church_id: candidate.id, workers: take} | plan], remaining - take}
            else
              {plan, remaining}
            end
        end
      end)

    {Enum.reverse(plan), remaining}
  end

  # No federation needed: local capacity already covers the
  # requirement. Still a two-write process (mark_fulfilled + receipt),
  # so it commits atomically like every other terminal path here.
  defp fulfill_locally(requirement, request_id) do
    {:ok, receipt} =
      AshSupabase.Transaction.run(Repo, fn ->
        requirement
        |> Ash.Changeset.for_update(:mark_fulfilled, %{})
        |> Ash.update!()

        Receipt.create!(%{
          subject_type: @subject_type,
          subject_id: to_string(requirement.id),
          ontology_version: Ontology.version(),
          request_id: request_id,
          process: @process,
          admission: :admitted,
          outcome: :success,
          metadata: %{deficit: 0}
        })
      end)

    {:ok, :no_deficit, receipt}
  end

  # The full deficit is coverable: reserve from every candidate in the
  # plan, record the fulfillment, mark the requirement fulfilled, and
  # write the receipt -- all inside one transaction, so a failure at any
  # step rolls every reservation back too (no partial federation is
  # ever left committed).
  defp commit_federated_fulfillment(requirement, deficit, plan, request_id) do
    {:ok, receipt} =
      AshSupabase.Transaction.run(Repo, fn ->
        Enum.each(plan, fn %{partner_church_id: partner_church_id, workers: workers} ->
          PartnerChurch
          |> Ash.get!(partner_church_id)
          |> Ash.Changeset.for_update(:reserve, %{count: workers})
          |> Ash.update!()
        end)

        requirement
        |> Ash.Changeset.for_update(:record_fulfillment, %{additional_workers: deficit})
        |> Ash.update!()
        |> Ash.Changeset.for_update(:mark_fulfilled, %{})
        |> Ash.update!()

        Receipt.create!(%{
          subject_type: @subject_type,
          subject_id: to_string(requirement.id),
          ontology_version: Ontology.version(),
          request_id: request_id,
          process: @process,
          admission: :admitted,
          outcome: :success,
          metadata: %{
            deficit: deficit,
            local_available_workers: requirement.local_available_workers,
            fulfillment_plan: plan
          }
        })
      end)

    {:ok, :federated_fulfillment, receipt, plan}
  end

  # The deficit cannot be fully covered by any lawful candidate. Zero
  # PARTIAL/inconsistent reservation writes are ever made on this path
  # (nothing in `plan` was committed) -- but the refusal itself is a
  # receipted, durable, typed fact (BLOCKED:CAPABILITY_CAPACITY), never
  # a silent no-op, so marking the requirement blocked and writing the
  # receipt still happen, atomically, together.
  defp block(requirement, deficit, best_available, request_id) do
    {:ok, receipt} =
      AshSupabase.Transaction.run(Repo, fn ->
        requirement
        |> Ash.Changeset.for_update(:mark_blocked, %{})
        |> Ash.update!()

        Receipt.create!(%{
          subject_type: @subject_type,
          subject_id: to_string(requirement.id),
          ontology_version: Ontology.version(),
          request_id: request_id,
          process: @process,
          admission: :blocked,
          outcome: :blocked,
          refusal_type: "CAPABILITY_CAPACITY",
          metadata: %{deficit: deficit, best_available: best_available}
        })
      end)

    {:error, {:blocked, :capability_capacity, receipt}}
  end
end
