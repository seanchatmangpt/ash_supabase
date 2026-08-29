defmodule AshSupabase.Transformers.RequirePostgresDataLayer do
  @moduledoc """
  Ensures every `AshSupabase.Resource` is backed by `AshPostgres.DataLayer`.

  Supabase is a set of services (PostgREST, Realtime, GoTrue) layered on
  top of a single Postgres database. `AshSupabase` earns its guarantees --
  RLS lockdown, Realtime publication membership -- by putting resources in
  *that* database via `AshPostgres.DataLayer`. Any other data layer would
  make those guarantees meaningless, so this is a `Transformer` (which
  hard-fails compilation on error), not a `Verifier` (which only warns).
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def before?(_), do: true

  @impl true
  def transform(dsl_state) do
    data_layer = Transformer.get_persisted(dsl_state, :data_layer)
    module = Transformer.get_persisted(dsl_state, :module)

    if data_layer == AshPostgres.DataLayer do
      {:ok, dsl_state}
    else
      {:error,
       Spark.Error.DslError.exception(
         module: module,
         path: [:supabase],
         message: """
         AshSupabase.Resource requires `data_layer: AshPostgres.DataLayer`, \
         got: #{inspect(data_layer)}.

         Supabase is Postgres -- ash_supabase routes CRUD through \
         AshPostgres so the resource's table lives in the same database \
         Supabase serves via PostgREST/Realtime, and so the RLS/Realtime \
         SQL `mix ash_supabase.gen_policies` generates actually applies \
         to it.
         """
       )}
    end
  end
end
