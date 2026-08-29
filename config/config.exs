import Config

config :ash_supabase,
  ecto_repos: [AshSupabase.Test.Repo],
  ash_domains: [AshSupabase.Test.Domain]

# Ash's own recommended baseline config for apps on Ash >= 3.0.
config :ash, :include_embedded_source_by_default?, false
config :ash, :default_belongs_to_type, :uuid
config :ash, :known_types, []

config :spark, :formatter,
  remove_parens?: true,
  "Ash.Resource": [
    section_order: [
      :supabase,
      :events,
      :postgres,
      :attributes,
      :relationships,
      :actions,
      :policies,
      :code_interface
    ]
  ]

if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
