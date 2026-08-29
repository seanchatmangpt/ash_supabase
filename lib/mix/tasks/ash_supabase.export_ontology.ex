defmodule Mix.Tasks.AshSupabase.ExportOntology do
  @shortdoc "Export every gateway-exposed Ash action as an RDF ontology for ggen_igniter"

  @moduledoc """
  #{@shortdoc}.

      mix ash_supabase.export_ontology

  Introspects every resource `AshSupabase.Info.gateway_resources/1`
  returns (every `AshSupabase.Resource` with a non-empty `supabase do
  gateway_actions [...] end`) and writes an RDF/Turtle ontology to
  `priv/ggen/ash-supabase-client-pack/ontology.ttl` describing, for each
  gateway-exposed action, exactly what a client needs to call it -- and
  for each such resource, exactly what its records look like -- with no
  Ash- or Elixir-specific vocabulary in the ontology itself (attribute
  names and JSON-representable types only).

  This is the one place "the closed model" (PRD-language: what a client
  is *allowed* to do) gets computed from the live Ash application, rather
  than hand-maintained separately -- `mix ggen_igniter.sync --pack
  ash-supabase-client-pack` (aliased as `mix ash_supabase.gen_client`,
  which runs both in sequence) then deterministically projects this
  ontology into a typed TypeScript client. Re-running this task after
  changing any resource's `gateway_actions`, attributes, or action
  arguments, followed by a `sync`, is how the generated client stays
  synchronized with the actual Ash domain -- exactly the drift ggen's own
  README describes itself as solving.

  ## Options

    * `--out PATH` -- write the ontology somewhere other than the
      `ash-supabase-client-pack` convention path (rarely needed).
  """

  use Mix.Task

  @default_out "priv/ggen/ash-supabase-client-pack/ontology.ttl"
  @prefix "https://hexdocs.pm/ash_supabase/ontology#"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("compile")
    Mix.Task.run("app.config")

    {opts, _argv} = OptionParser.parse!(argv, strict: [out: :string])
    otp_app = Mix.Project.config()[:app]
    out = opts[:out] || @default_out

    resources = AshSupabase.Info.gateway_resources(otp_app)

    if resources == [] do
      Mix.shell().info("""
      No gateway-exposed resources found (no `AshSupabase.Resource` with a \
      non-empty `supabase do gateway_actions [...] end`) under \
      `config :#{otp_app}, ash_domains: [...]`. Nothing to export.
      """)
    else
      turtle = render_turtle(resources)
      Mix.Generator.create_file(out, turtle, force: true)
    end
  end

  defp render_turtle(resources) do
    action_triples = Enum.flat_map(resources, &action_triples/1)
    type_triples = Enum.flat_map(resources, &type_triples/1)

    """
    @prefix as: <#{@prefix}> .

    #{Enum.join(action_triples, "\n\n")}

    #{Enum.join(type_triples, "\n\n")}
    """
  end

  defp action_triples(resource) do
    table = AshPostgres.DataLayer.Info.table(resource)
    resource_short_name = resource |> Module.split() |> List.last()

    for action_name <- AshSupabase.Info.gateway_actions(resource) do
      action = Ash.Resource.Info.action(resource, action_name)
      params = action_params(resource, action)

      id = "action_#{table}_#{action_name}"
      ts_function_name = ts_function_name(action.type, resource_short_name)

      """
      as:#{id} a as:GatewayAction ;
        as:resourceName "#{table}" ;
        as:resourceModule "#{inspect(resource)}" ;
        as:actionName "#{action_name}" ;
        as:actionType "#{action.type}" ;
        as:tsFunctionName "#{ts_function_name}" ;
        as:tsReturnType "#{resource_short_name}" ;
        as:paramsJson \"\"\"#{Jason.encode!(params)}\"\"\" .
      """
    end
  end

  defp type_triples(resource) do
    table = AshPostgres.DataLayer.Info.table(resource)
    resource_short_name = resource |> Module.split() |> List.last()

    fields =
      resource
      |> Ash.Resource.Info.public_attributes()
      |> Enum.map(fn attr ->
        %{"name" => to_string(attr.name), "tsType" => ts_type(attr.type), "required" => true}
      end)

    [
      """
      as:type_#{table} a as:ResourceType ;
        as:resourceName "#{table}" ;
        as:tsInterfaceName "#{resource_short_name}" ;
        as:fieldsJson \"\"\"#{Jason.encode!(fields)}\"\"\" .
      """
    ]
  end

  # A create/update action's client-supplied params are its accepted
  # attributes plus its own arguments; a destroy action's is just `id`
  # (the record to destroy) plus any of its own arguments. `id` itself is
  # never in `accept` (see `AshSupabase.Resource`'s own gotcha about
  # `uuid_primary_key` not being writable by default) but every
  # update/destroy gateway call requires one (`AshSupabase.Gateway` reads
  # `params["id"]` before dispatch), so it's added explicitly here for
  # those two action types.
  defp action_params(resource, action) do
    accepted =
      case action.type do
        type when type in [:create, :update] ->
          Enum.map(action.accept || [], fn attr_name ->
            attribute = Ash.Resource.Info.attribute(resource, attr_name)

            %{
              "name" => to_string(attr_name),
              "tsType" => ts_type(attribute.type),
              "required" => !attribute.allow_nil?
            }
          end)

        _ ->
          []
      end

    arguments =
      Enum.map(action.arguments || [], fn arg ->
        %{
          "name" => to_string(arg.name),
          "tsType" => ts_type(arg.type),
          "required" => !arg.allow_nil?
        }
      end)

    id_param =
      if action.type in [:update, :destroy] do
        [%{"name" => "id", "tsType" => "string", "required" => true}]
      else
        []
      end

    id_param ++ accepted ++ arguments
  end

  defp ts_function_name(:create, resource_short_name), do: "create#{resource_short_name}"
  defp ts_function_name(:update, resource_short_name), do: "update#{resource_short_name}"
  defp ts_function_name(:destroy, resource_short_name), do: "delete#{resource_short_name}"
  defp ts_function_name(_type, resource_short_name), do: "call#{resource_short_name}"

  defp ts_type(Ash.Type.UUID), do: "string"
  defp ts_type(Ash.Type.String), do: "string"
  defp ts_type(Ash.Type.CiString), do: "string"
  defp ts_type(Ash.Type.Integer), do: "number"
  defp ts_type(Ash.Type.Float), do: "number"
  defp ts_type(Ash.Type.Decimal), do: "number"
  defp ts_type(Ash.Type.Boolean), do: "boolean"
  defp ts_type(Ash.Type.Atom), do: "string"
  defp ts_type(Ash.Type.Map), do: "Record<string, unknown>"
  defp ts_type(Ash.Type.UtcDatetime), do: "string"
  defp ts_type(Ash.Type.UtcDatetimeUsec), do: "string"
  defp ts_type(Ash.Type.NaiveDatetime), do: "string"
  defp ts_type(Ash.Type.Date), do: "string"
  defp ts_type({:array, inner}), do: "#{ts_type(inner)}[]"
  defp ts_type(:uuid), do: "string"
  defp ts_type(:string), do: "string"
  defp ts_type(:integer), do: "number"
  defp ts_type(:boolean), do: "boolean"
  defp ts_type(:atom), do: "string"
  defp ts_type(:map), do: "Record<string, unknown>"
  defp ts_type(_other), do: "unknown"
end
