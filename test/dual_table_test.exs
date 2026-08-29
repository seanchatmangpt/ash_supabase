defmodule AshSupabase.DualTableTest do
  @moduledoc """
  Proves the dual-table event-sourcing pattern end to end against a real
  Postgres database: every create/update/destroy on `Todo` (an
  `AshSupabase.Resource`) writes both the live `todos` row *and* an
  `events` row, in one transaction, with no code path that produces one
  without the other.
  """

  use AshSupabase.DataCase, async: true

  describe "create" do
    test "writes the live row and an event, atomically" do
      user = create_user!()

      todo =
        Todo
        |> Ash.Changeset.for_create(:create, %{title: "Buy milk", user_id: user.id}, actor: user)
        |> Ash.create!()

      assert todo.title == "Buy milk"
      assert todo.completed == false

      [event] = events_for(todo.id)

      assert event.resource == Todo
      assert event.action == :create
      assert event.action_type == :create
      assert event.record_id == todo.id
      assert event.data["title"] == "Buy milk"
      assert event.user_id == user.id
    end

    test "an unauthenticated create is refused before it ever reaches the table" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Todo
               |> Ash.Changeset.for_create(:create, %{title: "nope", user_id: Ash.UUID.generate()})
               |> Ash.create()

      assert Repo.aggregate(AshSupabase.Test.Todos.Todo, :count) == 0
      assert events_count() == 0
    end
  end

  describe "update" do
    test "writes the updated row and a second event" do
      user = create_user!()
      todo = create_todo!(user, title: "Buy milk")

      updated =
        todo
        |> Ash.Changeset.for_update(:update, %{title: "Buy oat milk"}, actor: user)
        |> Ash.update!()

      assert updated.title == "Buy oat milk"

      events = events_for(todo.id)
      assert length(events) == 2
      assert Enum.map(events, & &1.action) == [:create, :update]
      assert List.last(events).data["title"] == "Buy oat milk"
    end

    test "another actor cannot update someone else's todo -- and no event is written" do
      owner = create_user!()
      other = create_user!()
      todo = create_todo!(owner, title: "private")

      assert {:error, %Ash.Error.Forbidden{}} =
               todo
               |> Ash.Changeset.for_update(:update, %{title: "hijacked"}, actor: other)
               |> Ash.update()

      assert Repo.reload!(todo).title == "private"
      assert length(events_for(todo.id)) == 1
    end
  end

  describe "destroy" do
    test "removes the live row and appends a destroy event" do
      user = create_user!()
      todo = create_todo!(user, title: "Buy milk")

      :ok =
        todo
        |> Ash.Changeset.for_destroy(:destroy, %{}, actor: user)
        |> Ash.destroy!()

      refute Repo.get(AshSupabase.Test.Todos.Todo, todo.id)

      events = events_for(todo.id)
      assert Enum.map(events, & &1.action) == [:create, :destroy]
    end
  end

  describe "replay" do
    test "rebuilding the todos table from the event log alone reproduces live state" do
      user = create_user!()
      todo = create_todo!(user, title: "Buy milk")

      todo
      |> Ash.Changeset.for_update(:update, %{title: "Buy oat milk", completed: true}, actor: user)
      |> Ash.update!()

      before_replay = Repo.get(AshSupabase.Test.Todos.Todo, todo.id)

      Event
      |> Ash.ActionInput.for_action(:replay, %{})
      |> Ash.run_action!()

      after_replay = Repo.get(AshSupabase.Test.Todos.Todo, todo.id)

      assert after_replay.id == before_replay.id
      assert after_replay.title == before_replay.title
      assert after_replay.completed == before_replay.completed
      assert after_replay.user_id == before_replay.user_id
    end
  end

  defp create_todo!(user, attrs) do
    Todo
    |> Ash.Changeset.for_create(:create, Map.new(attrs) |> Map.put(:user_id, user.id),
      actor: user
    )
    |> Ash.create!()
  end

  defp events_for(record_id) do
    Event
    |> Ash.Query.for_read(:for_record, %{record_id: record_id})
    |> Ash.read!()
  end

  defp events_count do
    Repo.aggregate(AshSupabase.Test.Events.Event, :count)
  end
end
