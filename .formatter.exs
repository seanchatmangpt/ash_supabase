spark_locals_without_parens = [
  table: 1,
  schema: 1,
  client: 1,
  endpoint: 1,
  primary_key_columns: 1,
  count: 1,
  returning?: 1,
  headers: 1,
  on_conflict: 1
]

[
  import_deps: [:ash, :spark],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  plugins: [Spark.Formatter],
  export: [locals_without_parens: spark_locals_without_parens],
  locals_without_parens: spark_locals_without_parens
]
