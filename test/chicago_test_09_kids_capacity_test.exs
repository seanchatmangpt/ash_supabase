defmodule AshSupabase.ChicagoTest09KidsCapacityTest do
  @moduledoc """
  Chicago Test 9 (PRD v26.8.29 §25-26): Kids capacity + federation, the
  architectural crown capability.

  Proves `AshSupabase.Test.Kids.FulfillmentSolver.fulfill/2` against a
  real Postgres database, in both directions:

    * when the deficit *can* be covered by verified partner-church
      capacity, federation commits: the requirement's `fulfilled_workers`
      / `status`, and the partner church's `reserved_workers`, all
      reflect the plan after reloading from the database, and exactly
      one admitted receipt exists.
    * when the deficit *cannot* be covered (every verified candidate is
      exhausted), the requirement is deterministically typed-blocked
      (`BLOCKED:CAPABILITY_CAPACITY`) and -- critically -- *no* partial
      reservation is left committed anywhere: every partner church's
      `reserved_workers` is provably unchanged.
  """

  use AshSupabase.DataCase, async: true

  alias AshSupabase.Test.Federation.PartnerChurch
  alias AshSupabase.Test.Kids.FulfillmentSolver
  alias AshSupabase.Test.Kids.StaffingRequirement

  describe "local capacity already covers the requirement (no deficit)" do
    test "fulfills without touching any partner church" do
      requirement = create_requirement!(required_workers: 5, local_available_workers: 6)
      request_id = Ash.UUID.generate()

      assert {:ok, :no_deficit, receipt} = FulfillmentSolver.fulfill(requirement.id, request_id)

      reloaded_requirement = Repo.reload!(requirement)
      assert reloaded_requirement.status == :fulfilled
      assert reloaded_requirement.fulfilled_workers == 0

      assert receipt.admission == :admitted
      assert receipt.outcome == :success
      assert receipt.metadata["deficit"] == 0
    end
  end

  describe "federated fulfillment (deficit fully coverable)" do
    test "commits reservations, fulfills the requirement, and writes an admitted receipt" do
      requirement = create_requirement!(required_workers: 8, local_available_workers: 5)

      partner =
        create_partner!(
          name: "Grace Fellowship",
          qualified_available_workers: 5,
          verified_safeguarding: true,
          distance_miles: 10
        )

      request_id = Ash.UUID.generate()

      assert {:ok, :federated_fulfillment, receipt, plan} =
               FulfillmentSolver.fulfill(requirement.id, request_id)

      # Deficit is 8 - 5 = 3, fully covered by the single partner.
      assert plan == [%{partner_church_id: partner.id, workers: 3}]

      reloaded_requirement = Repo.reload!(requirement)
      assert reloaded_requirement.fulfilled_workers == 3
      assert reloaded_requirement.status == :fulfilled

      reloaded_partner = Repo.reload!(partner)
      assert reloaded_partner.reserved_workers == 3

      assert receipt.subject_type == "KidsStaffingRequirement"
      assert receipt.subject_id == requirement.id
      assert receipt.request_id == request_id
      assert receipt.process == "AshSupabase.Test.Kids.FulfillmentSolver.fulfill"
      assert receipt.admission == :admitted
      assert receipt.outcome == :success
      assert receipt.ontology_version == AshSupabase.Test.Ontology.version()
      assert receipt.metadata["deficit"] == 3
    end
  end

  describe "federated fulfillment (deficit exceeds all verified candidates combined)" do
    test "blocks with a typed CAPABILITY_CAPACITY receipt and leaves zero partial reservations" do
      requirement = create_requirement!(required_workers: 10, local_available_workers: 2)

      # Deficit is 8; this verified partner can only ever offer 3, no
      # matter how the solver walks the (single-entry) candidate list.
      partner =
        create_partner!(
          name: "Small Chapel",
          qualified_available_workers: 3,
          verified_safeguarding: true,
          distance_miles: 4
        )

      request_id = Ash.UUID.generate()

      assert {:error, {:blocked, :capability_capacity, receipt}} =
               FulfillmentSolver.fulfill(requirement.id, request_id)

      reloaded_requirement = Repo.reload!(requirement)
      assert reloaded_requirement.status == :blocked
      # No partial credit -- a blocked requirement never has a nonzero
      # fulfilled_workers left over from a would-be partial reservation.
      assert reloaded_requirement.fulfilled_workers == 0

      # The "zero partial writes" assertion: the only verified candidate
      # in the graph was walked (its full 3-worker capacity would have
      # been taken had the plan committed), but since the *overall* plan
      # never covered the deficit, nothing was ever reserved from it.
      reloaded_partner = Repo.reload!(partner)
      assert reloaded_partner.reserved_workers == 0

      assert receipt.subject_type == "KidsStaffingRequirement"
      assert receipt.subject_id == requirement.id
      assert receipt.admission == :blocked
      assert receipt.outcome == :blocked
      assert receipt.refusal_type == "CAPABILITY_CAPACITY"
      assert receipt.metadata["deficit"] == 8
      assert receipt.metadata["best_available"] == 3
    end
  end

  defp create_requirement!(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:service_name, "Sunday AM Kids Room")

    StaffingRequirement
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!()
  end

  defp create_partner!(attrs) do
    PartnerChurch
    |> Ash.Changeset.for_create(:create, Map.new(attrs))
    |> Ash.create!()
  end
end
