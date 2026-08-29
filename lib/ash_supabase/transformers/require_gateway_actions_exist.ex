defmodule AshSupabase.Transformers.RequireGatewayActionsExist do
  @moduledoc """
  Ensures every action name listed in `supabase do gateway_actions [...]
  end` actually exists on the resource.

  Catches a typo (`gateway_actions [:cretae]`) at compile time instead of
  as a confusing runtime 404 from `AshSupabase.Gateway` the first time a
  client calls it -- the same "fail loudly, fail early" discipline
  `AshSupabase.Transformers.RequireEventSourcing` applies to the
  dual-table wiring itself.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    gateway_actions = Transformer.get_option(dsl_state, [:supabase], :gateway_actions) || []

    action_names =
      dsl_state
      |> Transformer.get_entities([:actions])
      |> MapSet.new(& &1.name)

    missing = Enum.reject(gateway_actions, &MapSet.member?(action_names, &1))

    if missing == [] do
      {:ok, dsl_state}
    else
      {:error,
       Spark.Error.DslError.exception(
         module: module,
         path: [:supabase, :gateway_actions],
         message: """
         supabase do gateway_actions [...] end names #{inspect(missing)}, which \
         #{if length(missing) == 1, do: "is", else: "are"} not #{if length(missing) == 1, do: "an action", else: "actions"} \
         defined on this resource.

         Known actions: #{inspect(Enum.sort(action_names))}
         """
       )}
    end
  end
end
