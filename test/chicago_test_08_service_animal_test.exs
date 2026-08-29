defmodule AshSupabase.ChicagoTest08ServiceAnimalTest do
  @moduledoc """
  PRD v26.8.29 Chicago Test 8 -- Service Animal interactions: "must not
  improvise policy text". `AshSupabase.Test.ServiceAnimal.route/2` is a
  closed, deterministic rule table, not free text generated per
  request -- this proves that determinism directly (call twice with the
  same condition, different request ids, and get the identical response
  both times) and that every classification still writes a Receipt.
  """

  use AshSupabase.DataCase, async: true

  alias AshSupabase.Test.Receipts.Receipt
  alias AshSupabase.Test.ServiceAnimal

  @cases [
    {:standard_pet_question, :no_action_required},
    {:handler_separated, :route_to_handler_reunification},
    {:aggressive_behavior, :route_to_safety_team}
  ]

  describe "route/2" do
    for {condition, expected_response} <- @cases do
      test "#{condition} classifies deterministically to #{expected_response} and receipts every call" do
        condition = unquote(condition)
        expected_response = unquote(expected_response)

        request_id_1 = Ash.UUID.generate()
        request_id_2 = Ash.UUID.generate()

        assert {:ok, response_1} = ServiceAnimal.route(condition, request_id_1)
        assert {:ok, response_2} = ServiceAnimal.route(condition, request_id_2)

        # The point of Test 8: the same condition always classifies to
        # the same response -- there is no room for improvisation.
        assert response_1 == expected_response
        assert response_2 == expected_response
        assert response_1 == response_2

        [receipt_1] = Receipt.for_subject!("ServiceAnimalInteraction", request_id_1)
        [receipt_2] = Receipt.for_subject!("ServiceAnimalInteraction", request_id_2)

        assert receipt_1.process == "AshSupabase.Test.ServiceAnimal.route"
        assert receipt_1.admission == :admitted
        assert receipt_1.outcome == :success
        assert receipt_1.metadata["condition"] == to_string(condition)
        assert receipt_1.metadata["response"] == to_string(expected_response)

        assert receipt_2.metadata["condition"] == to_string(condition)
        assert receipt_2.metadata["response"] == to_string(expected_response)
      end
    end
  end

  describe "route/2 -- table-driven cross-check" do
    test "every declared condition has exactly one, distinct classification" do
      responses =
        Enum.map(@cases, fn {condition, _expected} ->
          {:ok, response} = ServiceAnimal.route(condition, Ash.UUID.generate())
          response
        end)

      assert length(Enum.uniq(responses)) == length(@cases)
    end
  end
end
