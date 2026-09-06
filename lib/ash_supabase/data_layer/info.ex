defmodule AshSupabase.DataLayer.Info do
  @moduledoc "Introspection helpers for the `supabase` DSL section."

  alias Spark.Dsl.Extension

  @doc "The table or view backing the resource."
  @spec table(Ash.Resource.t() | Spark.Dsl.t()) :: String.t() | nil
  def table(resource), do: Extension.get_opt(resource, [:supabase], :table, nil, true)

  @doc "The client module used to reach the project."
  @spec client(Ash.Resource.t() | Spark.Dsl.t()) :: module() | nil
  def client(resource), do: Extension.get_opt(resource, [:supabase], :client, nil, true)

  @doc "The Postgres schema, or `nil` to use the client's default."
  @spec schema(Ash.Resource.t() | Spark.Dsl.t()) :: String.t() | nil
  def schema(resource), do: Extension.get_opt(resource, [:supabase], :schema, nil, true)

  @doc "Which counting strategy `Ash.Query.page/2` should use."
  @spec count_strategy(Ash.Resource.t() | Spark.Dsl.t()) :: :exact | :planned | :estimated
  def count_strategy(resource),
    do: Extension.get_opt(resource, [:supabase], :count_strategy, :exact, true)

  @doc "Whether unfiltered bulk updates and destroys are permitted."
  @spec allow_unfiltered_writes?(Ash.Resource.t() | Spark.Dsl.t()) :: boolean()
  def allow_unfiltered_writes?(resource),
    do: Extension.get_opt(resource, [:supabase], :allow_unfiltered_writes?, false, true)

  @doc "Extra headers sent with every request for this resource."
  @spec headers(Ash.Resource.t() | Spark.Dsl.t()) :: [{String.t(), String.t()}]
  def headers(resource), do: Extension.get_opt(resource, [:supabase], :headers, [], true)
end
