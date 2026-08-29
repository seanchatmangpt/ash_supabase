import Config

config :ash_supabase, AshSupabase.Test.Repo,
  username: System.get_env("PGUSER", "ash_supabase"),
  password: System.get_env("PGPASSWORD", "ash_supabase"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: System.get_env("PGDATABASE", "ash_supabase_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :ash_supabase, :ecto_repos, [AshSupabase.Test.Repo]

# Keep test output deterministic: run Ash actions synchronously.
config :ash, :disable_async?, true

config :logger, level: :warning
