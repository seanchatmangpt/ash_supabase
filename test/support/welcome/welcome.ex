defmodule AshSupabase.Test.Welcome do
  @moduledoc """
  The Welcome / Infant Room / Escort scenarios (PRD v26.8.29 §23, §27),
  each instantiating the generic obligation grammar:

      Threshold -> Signal -> Classification -> Owner -> Obligation
        -> Action -> Receipt -> NextState

  Every function here is a trusted, internal, deterministic process --
  none of it is an LLM improvising policy; the *decisions* (who greets
  whom, whether a parent needed informing, whether an escort is safe to
  release) are made upstream by the Welcome Team's own rule-based
  workflow. This module's only job is to durably record that decision
  as a closed, typed Obligation plus a Receipt, atomically, so that
  §27's invariant -- "No obligation may silently disappear" -- holds
  for every one of these scenarios.
  """

  alias AshSupabase.Test.Obligations.Obligation
  alias AshSupabase.Test.Ontology
  alias AshSupabase.Test.Receipts.Receipt
  alias AshSupabase.Test.Repo
  alias AshSupabase.Test.Welcome.Post

  # Every write in this module happens on behalf of a trusted internal
  # process, not a directly-authenticated end user -- `actor_present()`
  # is the only policy check `Obligation` requires, and any non-nil
  # term satisfies it.
  @system_actor :system

  @infant_room_labels %{
    informed: "INFORMED",
    declined: "DECLINED",
    routed: "ROUTED",
    not_applicable: "NOT_APPLICABLE"
  }

  @doc """
  Chicago Test 5's threshold crossing: opens a `:welcome` obligation for
  `subject_id`, assigns `owner_id` as the greeter, and closes it
  `:completed` with `outcome_label: "GREETED"` -- all in one
  transaction, with a receipt.
  """
  def cross_threshold(subject_id, request_id, owner_id) do
    AshSupabase.Transaction.run(Repo, fn ->
      obligation =
        Obligation.create!(%{kind: :welcome, subject_id: subject_id}, actor: @system_actor)

      obligation =
        Obligation.assign_owner!(obligation, %{owner_id: owner_id}, actor: @system_actor)

      obligation =
        Obligation.complete!(obligation, %{outcome_label: "GREETED"}, actor: @system_actor)

      receipt =
        Receipt.create!(
          %{
            subject_type: "Obligation",
            subject_id: to_string(obligation.id),
            ontology_version: Ontology.version(),
            request_id: request_id,
            process: "AshSupabase.Test.Welcome.cross_threshold",
            admission: :admitted,
            outcome: :success,
            events_created: 3,
            metadata: %{
              subject_id: to_string(subject_id),
              owner_id: to_string(owner_id),
              outcome_label: "GREETED"
            }
          },
          actor: @system_actor
        )

      {obligation, receipt}
    end)
    |> case do
      {:ok, {obligation, receipt}} -> {:ok, obligation, receipt}
    end
  end

  @doc """
  The gate Chicago Test 5 requires: the security-stage transition may
  occur only after `subject_id`'s welcome state is satisfied, i.e. at
  least one `:welcome` obligation for them has reached `:completed`.
  """
  def security_stage_allowed?(subject_id) do
    subject_id
    |> Obligation.for_subject_and_kind!(:welcome, actor: @system_actor)
    |> Enum.any?(&(&1.status == :completed))
  end

  @doc """
  Chicago Test 6: durably records the Welcome Team's already-made
  infant-room decision as a closed `:infant_room` obligation. `decision`
  is one of `:informed | :declined | :routed | :not_applicable` --
  whichever it is, the obligation is always created and always closed
  `:completed`, with `outcome_label` carrying which of the PRD's
  terminal labels actually applied. This function does not decide
  anything; it only makes the upstream decision durable, so that
  `:not_applicable` (nothing needed to happen) still produces a
  first-class, queryable obligation instead of silently doing nothing.
  """
  def inform_parent_room(subject_id, request_id, decision)
      when decision in [:informed, :declined, :routed, :not_applicable] do
    outcome_label = Map.fetch!(@infant_room_labels, decision)

    AshSupabase.Transaction.run(Repo, fn ->
      obligation =
        Obligation.create!(%{kind: :infant_room, subject_id: subject_id}, actor: @system_actor)

      obligation =
        Obligation.complete!(obligation, %{outcome_label: outcome_label}, actor: @system_actor)

      receipt =
        Receipt.create!(
          %{
            subject_type: "Obligation",
            subject_id: to_string(obligation.id),
            ontology_version: Ontology.version(),
            request_id: request_id,
            process: "AshSupabase.Test.Welcome.inform_parent_room",
            admission: :admitted,
            outcome: :success,
            metadata: %{subject_id: to_string(subject_id), decision: to_string(decision)}
          },
          actor: @system_actor
        )

      {obligation, receipt}
    end)
    |> case do
      {:ok, {obligation, receipt}} -> {:ok, obligation, receipt}
    end
  end

  @doc """
  Chicago Test 7: releases one escort from `post_id`'s coverage to
  accompany `subject_id`.

  The coverage-invariant check runs *before* any database transaction
  opens (`Coverage(W,t) - 1 < minimum_coverage`, PRD §23) -- unless
  `opts[:replacement_reserved?]` is `true`, a request that would drop a
  post below its minimum is refused with **zero writes**: no
  Obligation row, no coverage change, nothing. Only once that check
  passes does this open a transaction to create the `:escort`
  obligation, decrement coverage, close the obligation `:completed`
  (`outcome_label: "ESCORTED"`), and write the receipt.
  """
  def request_escort(post_id, subject_id, request_id, opts \\ []) do
    post = Post.by_id!(post_id, actor: @system_actor)
    remaining = post.current_coverage - 1

    if remaining < post.minimum_coverage and opts[:replacement_reserved?] != true do
      {:error, {:blocked, :coverage, "escort would drop coverage below minimum"}}
    else
      AshSupabase.Transaction.run(Repo, fn ->
        obligation =
          Obligation.create!(%{kind: :escort, subject_id: subject_id}, actor: @system_actor)

        updated_post = Post.adjust_coverage!(post, %{delta: -1}, actor: @system_actor)

        obligation =
          Obligation.complete!(obligation, %{outcome_label: "ESCORTED"}, actor: @system_actor)

        receipt =
          Receipt.create!(
            %{
              subject_type: "Obligation",
              subject_id: to_string(obligation.id),
              ontology_version: Ontology.version(),
              request_id: request_id,
              process: "AshSupabase.Test.Welcome.request_escort",
              admission: :admitted,
              outcome: :success,
              # Coverage releases are not a financial process -- an empty
              # list is the correct, honest value here, not an omission.
              financial_postings: [],
              metadata: %{
                subject_id: to_string(subject_id),
                post_id: to_string(post_id),
                remaining_coverage: updated_post.current_coverage,
                replacement_reserved?: opts[:replacement_reserved?] == true
              }
            },
            actor: @system_actor
          )

        {obligation, receipt}
      end)
      |> case do
        {:ok, {obligation, receipt}} -> {:ok, obligation, receipt}
      end
    end
  end
end
