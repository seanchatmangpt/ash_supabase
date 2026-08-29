defmodule AshSupabase.Test.ServiceAnimal do
  @moduledoc """
  The service-animal-interaction scenario (PRD v26.8.29 §27, Chicago
  Test 8: "must not improvise policy text"). No new obligation resource
  is needed here -- there is nothing to own or hand off, only a
  classification to make durable.

  `route/2` is deliberately a closed, deterministic rule table rather
  than free text or anything an LLM composes at request time: the same
  `condition` must always classify to the exact same response, forever
  -- that determinism *is* the point being proven, not an incidental
  property.
  """

  alias AshSupabase.Test.Ontology
  alias AshSupabase.Test.Receipts.Receipt
  alias AshSupabase.Test.Repo

  @system_actor :system

  # The one and only source of truth for how each condition classifies
  # -- closed, not configurable, not free-text.
  @responses %{
    standard_pet_question: :no_action_required,
    handler_separated: :route_to_handler_reunification,
    aggressive_behavior: :route_to_safety_team
  }

  @conditions Map.keys(@responses)

  @doc """
  Classifies `condition` (one of `:standard_pet_question |
  :handler_separated | :aggressive_behavior`) deterministically and
  returns `{:ok, response}`, writing a Receipt as a durable record of
  the classification. Calling this twice with the same `condition`
  (any `request_id`) always returns the identical `response`.
  """
  def route(condition, request_id) when condition in @conditions do
    response = Map.fetch!(@responses, condition)

    {:ok, _receipt} =
      AshSupabase.Transaction.run(Repo, fn ->
        Receipt.create!(
          %{
            subject_type: "ServiceAnimalInteraction",
            subject_id: request_id,
            ontology_version: Ontology.version(),
            request_id: request_id,
            process: "AshSupabase.Test.ServiceAnimal.route",
            admission: :admitted,
            outcome: :success,
            metadata: %{condition: to_string(condition), response: to_string(response)}
          },
          actor: @system_actor
        )
      end)

    {:ok, response}
  end
end
