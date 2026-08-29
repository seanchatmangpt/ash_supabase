defmodule AshSupabase.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/seanchatmangpt/ash_supabase"

  def project do
    [
      app: :ash_supabase,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      aliases: aliases(),
      docs: docs(),
      package: package(),
      description: description(),
      source_url: @source_url,
      homepage_url: @source_url,
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.html": :test,
        "test.setup": :test,
        "test.reset": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AshSupabase.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # -- Ash ecosystem: the resource layer that fronts every table --
      {:ash, "~> 3.32"},
      {:ash_postgres, "~> 2.12"},
      {:ash_events, "~> 0.7"},
      {:spark, "~> 2.7"},
      {:igniter, "~> 0.8", optional: true},

      # SAT solver Ash.Policy.Authorizer needs at compile time to verify
      # policies are satisfiable. Pure Elixir -- no NIF to compile.
      {:simple_sat, "~> 0.1"},

      # -- Data + crypto --
      {:ecto_sql, "~> 3.14"},
      {:postgrex, ">= 0.0.0"},
      {:jason, "~> 1.4"},

      # -- Dev / test only --
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "test.setup": ["ash_postgres.create", "ash_postgres.migrate"],
      "test.reset": ["ash_postgres.drop", "test.setup"],
      test: ["test.setup", "test"]
    ]
  end

  defp description do
    "Ash Framework integration for Supabase: routes every Supabase CRUD operation " <>
      "through Ash resources backed by a dual-table event-sourcing data layer " <>
      "(AshPostgres projection table + AshEvents event log), plus RLS/Realtime " <>
      "policy generation and Supabase Auth actor bridging."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
