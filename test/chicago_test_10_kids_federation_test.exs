defmodule AshSupabase.ChicagoTest10KidsFederationTest do
  @moduledoc """
  Chicago Test 10 (PRD v26.8.29 §25-26): a required *capability* does
  not imply a required *local implementation* -- but it does imply a
  required fulfillment path.

  Two things this test proves against a real Postgres database:

    1. With **zero** local capacity at all, a verified partner church
       with enough capacity fully fulfills the requirement entirely via
       federation -- the requirement's local contribution stays exactly
       zero and the requirement still reaches `:fulfilled`.
    2. `verified_safeguarding` is a **hard constraint**, not a scoring
       preference: an unverified partner with plenty of raw capacity
       (and even a closer/more attractive distance) is never drawn from,
       even though it would numerically be more than enough on its own.
       Its `reserved_workers` stays 0 no matter what.
  """

  use AshSupabase.DataCase, async: true

  alias AshSupabase.Test.Federation.PartnerChurch
  alias AshSupabase.Test.Kids.FulfillmentSolver
  alias AshSupabase.Test.Kids.StaffingRequirement

  test "zero local capacity still fulfills entirely via federation, and an unverified partner is never drawn from" do
    requirement =
      StaffingRequirement
      |> Ash.Changeset.for_create(:create, %{
        service_name: "Wednesday Nursery",
        required_workers: 6,
        local_available_workers: 0
      })
      |> Ash.create!()

    # Closer, and has more than enough raw capacity on its own -- but is
    # NOT safeguarding-verified. If the solver ever drew from this
    # candidate, it would numerically "solve" the deficit trivially and
    # nearer-first ordering would even put it first in line. It must
    # never be touched.
    unverified_partner =
      PartnerChurch
      |> Ash.Changeset.for_create(:create, %{
        name: "Unverified Storefront Church",
        qualified_available_workers: 100,
        verified_safeguarding: false,
        distance_miles: 1
      })
      |> Ash.create!()

    # Farther away, exactly enough capacity, and IS verified -- the only
    # lawful fulfillment source in this graph.
    verified_partner =
      PartnerChurch
      |> Ash.Changeset.for_create(:create, %{
        name: "Verified Federation Partner",
        qualified_available_workers: 6,
        verified_safeguarding: true,
        distance_miles: 50
      })
      |> Ash.create!()

    request_id = Ash.UUID.generate()

    assert {:ok, :federated_fulfillment, receipt, plan} =
             FulfillmentSolver.fulfill(requirement.id, request_id)

    # Only the verified partner appears in the committed plan.
    assert plan == [%{partner_church_id: verified_partner.id, workers: 6}]

    reloaded_requirement = Repo.reload!(requirement)
    assert reloaded_requirement.status == :fulfilled
    assert reloaded_requirement.fulfilled_workers == 6
    # Local contribution stayed exactly zero -- the requirement's own
    # local_available_workers attribute is untouched by federation.
    assert reloaded_requirement.local_available_workers == 0

    reloaded_verified_partner = Repo.reload!(verified_partner)
    assert reloaded_verified_partner.reserved_workers == 6

    # The hard-constraint assertion: no matter how much raw capacity it
    # reported, or how much closer it was, the unverified partner's
    # reserved_workers never moves off zero.
    reloaded_unverified_partner = Repo.reload!(unverified_partner)
    assert reloaded_unverified_partner.reserved_workers == 0

    assert receipt.admission == :admitted
    assert receipt.outcome == :success
    assert receipt.metadata["local_available_workers"] == 0
    assert receipt.metadata["deficit"] == 6
  end
end
