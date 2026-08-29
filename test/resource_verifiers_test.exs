defmodule AshSupabase.ResourceVerifiersTest do
  @moduledoc """
  `AshSupabase.Resource` is meant to make "no CRUD without an event"
  structurally true, not just documented -- these prove misconfigured
  resources fail to compile rather than silently skipping the event log.
  """

  use ExUnit.Case, async: true

  defp compile(source) do
    Code.compile_string(source)
  end

  test "a resource using AshSupabase.Resource without AshEvents.Events fails to compile" do
    source = """
    defmodule AshSupabase.Test.NoEvents.#{unique()} do
      use Ash.Resource,
        domain: nil,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshSupabase.Resource],
        validate_domain_inclusion?: false

      postgres do
        table "no_events"
        repo AshSupabase.Test.Repo
      end

      attributes do
        uuid_primary_key :id
      end
    end
    """

    error = assert_raise Spark.Error.DslError, fn -> compile(source) end
    assert error.message =~ "AshEvents.Events"
  end

  test "a resource using AshSupabase.Resource with AshEvents.Events but no event_log fails to compile" do
    source = """
    defmodule AshSupabase.Test.NoEventLog.#{unique()} do
      use Ash.Resource,
        domain: nil,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshSupabase.Resource, AshEvents.Events],
        validate_domain_inclusion?: false

      postgres do
        table "no_event_log"
        repo AshSupabase.Test.Repo
      end

      attributes do
        uuid_primary_key :id
      end
    end
    """

    error = assert_raise Spark.Error.DslError, fn -> compile(source) end
    assert error.message =~ "event_log"
  end

  test "a resource using AshSupabase.Resource with a non-Postgres data layer fails to compile" do
    source = """
    defmodule AshSupabase.Test.NotPostgres.#{unique()} do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshSupabase.Resource, AshEvents.Events],
        validate_domain_inclusion?: false

      events do
        event_log AshSupabase.Test.Events.Event
      end

      attributes do
        uuid_primary_key :id
      end
    end
    """

    error = assert_raise Spark.Error.DslError, fn -> compile(source) end
    assert error.message =~ "AshPostgres.DataLayer"
  end

  defp unique, do: "R#{System.unique_integer([:positive])}"
end
