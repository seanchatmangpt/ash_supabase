defmodule AshSupabase.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/seanchatmangpt/ash_supabase"
  @description """
  Supabase integration for the Ash Framework: a PostgREST-backed Ash data layer,
  GoTrue authentication with JWT verification, Storage, Realtime, and Postgres
  Row Level Security helpers.
  """

  def project do
    [
      app: :ash_supabase,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: @description,
      package: package(),
      docs: docs(),
      name: "AshSupabase",
      source_url: @source_url,
      aliases: aliases(),
      consolidate_protocols: Mix.env() != :test,
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.github": :test,
        credo: :test,
        dialyzer: :test
      ],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :plug, :ash_postgres],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        flags: [:unmatched_returns, :error_handling, :extra_return]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.33"},
      {:spark, "~> 2.7"},
      {:req, "~> 0.5 or ~> 0.7"},
      {:jason, "~> 1.4"},
      {:joken, "~> 2.6"},
      # Optional integrations
      {:plug, "~> 1.15", optional: true},
      {:ash_postgres, "~> 2.13", optional: true},
      {:igniter, "~> 0.8", optional: true},
      {:mint_web_socket, "~> 1.0", optional: true},
      # Dev/test
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      name: :ash_supabase,
      licenses: ["MIT"],
      files:
        ~w(lib documentation .formatter.exs mix.exs README.md LICENSE CHANGELOG.md usage-rules.md),
      links: %{
        "GitHub" => @source_url,
        "Ash Framework" => "https://ash-hq.org",
        "Supabase" => "https://supabase.com"
      },
      maintainers: ["Sean Chatman"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "documentation/tutorials/getting-started.md",
        "documentation/topics/data-layer.md",
        "documentation/topics/authentication.md",
        "documentation/topics/storage.md",
        "documentation/topics/realtime.md",
        "documentation/topics/rls.md",
        "documentation/topics/testing.md"
      ],
      groups_for_extras: [
        Tutorials: ~r"documentation/tutorials",
        Topics: ~r"documentation/topics"
      ],
      groups_for_modules: [
        "Data Layer": [
          AshSupabase.DataLayer,
          AshSupabase.DataLayer.Info
        ],
        Client: [
          AshSupabase.Client,
          AshSupabase.Config,
          AshSupabase.Error
        ],
        PostgREST: ~r"AshSupabase.PostgREST",
        Authentication: ~r"AshSupabase.Auth",
        Storage: ~r"AshSupabase.Storage",
        Realtime: ~r"AshSupabase.Realtime",
        "Row Level Security": ~r"AshSupabase.Rls",
        Plugs: [AshSupabase.Plug]
      ]
    ]
  end

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test"
      ]
    ]
  end
end
