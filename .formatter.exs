# Used by "mix format"
[
  import_deps: [:ash, :ash_postgres, :ash_events, :ecto, :ecto_sql],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  plugins: [Spark.Formatter]
]
