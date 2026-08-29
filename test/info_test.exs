defmodule AshSupabase.InfoTest do
  use ExUnit.Case, async: true

  alias AshSupabase.Info
  alias AshSupabase.Test.Events.Event
  alias AshSupabase.Test.Todos.Todo

  test "supabase_resource?/1 is true only for resources using AshSupabase.Resource" do
    assert Info.supabase_resource?(Todo)
    refute Info.supabase_resource?(Event)
    refute Info.supabase_resource?(AshSupabase.Test.Accounts.User)
  end

  test "Todo's configured supabase options are readable" do
    assert Info.realtime?(Todo) == true
    assert Info.expose_via_postgrest?(Todo) == false
    assert Info.postgrest_read_only?(Todo) == true
    assert Info.rls_authenticated_select?(Todo) == false
  end

  test "supabase_resources/1 finds every AshSupabase.Resource across the test domain" do
    resources = Info.supabase_resources(:ash_supabase)

    assert Todo in resources
    refute Event in resources
    refute AshSupabase.Test.Accounts.User in resources
    assert Enum.all?(resources, &Info.supabase_resource?/1)
  end
end
