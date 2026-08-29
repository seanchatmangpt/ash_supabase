defmodule AshSupabase.Test.Domain do
  @moduledoc """
  The Ash domain grouping the example resources used to exercise
  AshSupabase end to end: a Supabase-Auth-shaped `User`, the shared
  `AshEvents` event log, and a `Todo` resource that is fully wired for
  dual-table event-sourced CRUD.
  """

  use Ash.Domain, otp_app: :ash_supabase

  resources do
    resource AshSupabase.Test.Accounts.User
    resource AshSupabase.Test.Events.Event
    resource AshSupabase.Test.Todos.Todo
  end
end
