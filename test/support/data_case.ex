defmodule AshSupabase.DataCase do
  @moduledoc """
  ExUnit case template for tests that hit `AshSupabase.Test.Repo`.

  Each test runs inside an `Ecto.Adapters.SQL.Sandbox` transaction that's
  rolled back afterwards, so tests can freely create/update/destroy
  `Todo`s (and the events they produce) without polluting other tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias AshSupabase.Test.Accounts.User
      alias AshSupabase.Test.Events.Event
      alias AshSupabase.Test.Repo
      alias AshSupabase.Test.Todos.Todo

      import AshSupabase.DataCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(AshSupabase.Test.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc "Insert (bypassing Ash -- this row exists outside the event-sourced flow) a test user/actor."
  def create_user!(attrs \\ %{}) do
    id = Map.get(attrs, :id, Ash.UUID.generate())
    email = Map.get(attrs, :email, "user-#{id}@example.com")

    AshSupabase.Test.Accounts.User
    |> Ash.Changeset.for_create(:create, %{id: id, email: email})
    |> Ash.create!()
  end
end
