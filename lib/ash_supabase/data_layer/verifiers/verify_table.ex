defmodule AshSupabase.DataLayer.Verifiers.VerifyTable do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    resource = Verifier.get_persisted(dsl, :module)

    with :ok <- verify_table(dsl, resource) do
      verify_client(dsl, resource)
    end
  end

  defp verify_table(dsl, resource) do
    case AshSupabase.DataLayer.Info.table(dsl) do
      table when is_binary(table) and table != "" ->
        :ok

      _ ->
        {:error,
         Spark.Error.DslError.exception(
           module: resource,
           path: [:supabase, :table],
           message: """
           A table (or view) name is required.

               supabase do
                 table "posts"
                 client MyApp.Supabase
               end
           """
         )}
    end
  end

  defp verify_client(dsl, resource) do
    case AshSupabase.DataLayer.Info.client(dsl) do
      client when is_atom(client) and not is_nil(client) ->
        :ok

      _ ->
        {:error,
         Spark.Error.DslError.exception(
           module: resource,
           path: [:supabase, :client],
           message: """
           A client module is required, so the resource knows which Supabase project to talk to.

               supabase do
                 table "posts"
                 client MyApp.Supabase
               end

           Define the client with:

               defmodule MyApp.Supabase do
                 use AshSupabase.Client, otp_app: :my_app
               end
           """
         )}
    end
  end
end
