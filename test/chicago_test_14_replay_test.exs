defmodule AshSupabase.ChicagoTest14ReplayTest do
  @moduledoc """
  PRD v26.8.29 §14/§30/§34 "Read Architecture" / Chicago Test 14 --
  "Event Replay". `test/dual_table_test.exs` already proves replay
  field-by-field; this test independently proves the same claim as a
  *structural* one, via `AshSupabase.Replay.state_hash/2` /
  `AshSupabase.Replay.compare/2`: the hash of a record's public state,
  captured immediately before running `Event`'s `:replay` action, must
  equal the hash captured after reloading that same record post-replay.
  """

  use AshSupabase.DataCase, async: true

  alias AshSupabase.Replay

  test "state_hash before and after a full event replay are :alive (identical)" do
    user = create_user!()

    todo =
      Todo
      |> Ash.Changeset.for_create(:create, %{title: "Buy milk", user_id: user.id}, actor: user)
      |> Ash.create!()

    todo
    |> Ash.Changeset.for_update(:update, %{title: "Buy oat milk", completed: true}, actor: user)
    |> Ash.update!()

    before_replay = Repo.get(Todo, todo.id)
    hash_before = Replay.state_hash(Todo, before_replay)

    Event
    |> Ash.ActionInput.for_action(:replay, %{})
    |> Ash.run_action!()

    after_replay = Repo.get(Todo, todo.id)
    hash_after = Replay.state_hash(Todo, after_replay)

    # Belt-and-braces: the fields really are identical too, so a failure
    # of the hash assertion below could never be blamed on the fixture
    # itself having drifted for an unrelated reason.
    assert after_replay.title == before_replay.title
    assert after_replay.completed == before_replay.completed
    assert after_replay.user_id == before_replay.user_id

    assert Replay.compare(hash_before, hash_after) == :alive
  end

  test "state_hash depends only on public attributes -- not on struct instance or load path" do
    user = create_user!()

    todo =
      Todo
      |> Ash.Changeset.for_create(:create, %{title: "Buy milk", user_id: user.id}, actor: user)
      |> Ash.create!()

    # Two different struct instances of the exact same record, loaded via
    # two entirely different code paths: a raw Ecto struct straight off
    # the projection table, and a struct that went through Ash's read
    # pipeline (policies, `Ash.Resource.Info` metadata, `__meta__`
    # differences, ...). If `state_hash/2` were accidentally sensitive to
    # anything beyond `Ash.Resource.Info.public_attributes/1`, these two
    # would hash differently even though they describe the same state.
    via_repo = Repo.get(Todo, todo.id)
    via_ash = Ash.get!(Todo, todo.id, actor: user)

    hash_via_repo = Replay.state_hash(Todo, via_repo)
    hash_via_ash = Replay.state_hash(Todo, via_ash)

    assert Replay.compare(hash_via_repo, hash_via_ash) == :alive

    # And a genuine change in public state *is* detected as drift -- the
    # hash isn't just trivially equal to everything.
    drifted = %{via_repo | title: "a different title entirely"}
    hash_drifted = Replay.state_hash(Todo, drifted)

    assert {:drift, %{before: ^hash_via_repo, after: ^hash_drifted}} =
             Replay.compare(hash_via_repo, hash_drifted)

    assert hash_via_repo != hash_drifted
  end
end
