{:ok, _} = Application.ensure_all_started(:ash_supabase)
{:ok, _} = AshSupabase.Test.Repo.start_link()

Ecto.Adapters.SQL.Sandbox.mode(AshSupabase.Test.Repo, :manual)

ExUnit.start()
