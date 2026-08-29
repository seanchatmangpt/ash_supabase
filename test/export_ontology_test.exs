defmodule Mix.Tasks.AshSupabase.ExportOntologyTest do
  @moduledoc """
  Runs the real `mix ash_supabase.export_ontology` task (not a unit test
  of its private functions) and checks the actual Turtle it writes --
  the ontology `mix ggen_igniter.sync --pack ash-supabase-client-pack`
  then renders into the typed TypeScript client (see
  `test/ggen_client_sync_test.exs`, which is the test that actually
  proves the SPARQL queries in `priv/ggen/ash-supabase-client-pack/`
  read this file correctly).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @out Path.join([File.cwd!(), "priv", "ggen", "ash-supabase-client-pack", "ontology.ttl"])

  test "writes syntactically valid Turtle describing Todo's gateway actions and its resource type" do
    capture_io(fn ->
      Mix.Task.rerun("ash_supabase.export_ontology", [])
    end)

    assert File.exists?(@out)

    # The real proof of validity: an actual Turtle parser accepts it.
    graph = RDF.Turtle.read_file!(@out)
    refute Enum.empty?(RDF.Graph.triples(graph))

    turtle = File.read!(@out)

    # The Todo resource's three gateway_actions (create/update/destroy)
    # each produced one as:GatewayAction with the resource's own table
    # name, not its Elixir module name -- a client must never need to
    # know the latter.
    assert turtle =~ ~s(as:resourceName "todos")
    assert turtle =~ ~s(as:actionName "create")
    assert turtle =~ ~s(as:actionName "update")
    assert turtle =~ ~s(as:actionName "destroy")
    assert turtle =~ ~s(as:tsFunctionName "createTodo")
    assert turtle =~ ~s(as:tsFunctionName "updateTodo")
    assert turtle =~ ~s(as:tsFunctionName "deleteTodo")

    # A ResourceType entry for Todo, driving the generated `export
    # interface Todo { ... }` -- from the module's own last segment, not
    # a hand-maintained separate name.
    assert turtle =~ ~s(as:tsInterfaceName "Todo")
    assert turtle =~ "as:ResourceType"
  end

  test "the create action's paramsJson is valid JSON naming its accepted attributes" do
    capture_io(fn ->
      Mix.Task.rerun("ash_supabase.export_ontology", [])
    end)

    turtle = File.read!(@out)

    # Isolate the `create` action's own block by splitting on the
    # `as:action_todos_*` subject markers this task's own id scheme
    # produces, then find the one for `create`.
    [create_block] =
      turtle
      |> String.split(~r/\nas:action_todos_/)
      |> Enum.filter(&String.starts_with?(&1, "create "))

    [_, params_json] = Regex.run(~r/as:paramsJson\s+"""(.*?)"""/s, create_block)
    params = Jason.decode!(params_json)
    param_names = Enum.map(params, & &1["name"])

    assert "title" in param_names
    assert "user_id" in param_names
  end
end
