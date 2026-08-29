defmodule AshSupabase.Transformers.RequireEventSourcing do
  @moduledoc """
  Ensures every `AshSupabase.Resource` also uses `AshEvents.Events` with
  an `event_log` configured.

  This is the DSL-level enforcement of "all Supabase CRUD goes through
  Ash with a dual-table event-sourcing pattern": a resource cannot carry
  the `AshSupabase.Resource` extension without also getting an immutable
  event appended, in the same transaction, for every create/update/destroy
  it performs. There is no supported way to write to the resource's live
  table without also writing to the event log.

  Implemented as a `Transformer` rather than a `Verifier` so a
  misconfigured resource fails compilation outright instead of merely
  logging a warning.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def before?(_), do: true

  @impl true
  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    extensions = Transformer.get_persisted(dsl_state, :extensions) || []

    cond do
      AshEvents.Events not in extensions ->
        {:error, dsl_error(module, missing_extension_message())}

      is_nil(Transformer.get_option(dsl_state, [:events], :event_log)) ->
        {:error, dsl_error(module, missing_event_log_message())}

      true ->
        {:ok, dsl_state}
    end
  end

  defp dsl_error(module, message) do
    Spark.Error.DslError.exception(module: module, path: [:supabase], message: message)
  end

  defp missing_extension_message do
    """
    AshSupabase.Resource requires dual-table event sourcing via AshEvents, \
    but this resource does not have the `AshEvents.Events` extension applied.

    Every Supabase-backed resource must declare both extensions together \
    so create/update/destroy actions are captured as a durable, replayable \
    event log *in addition to* the live projection table AshPostgres \
    maintains -- one write, two tables, always:

        use Ash.Resource,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshSupabase.Resource, AshEvents.Events]

        events do
          event_log MyApp.Events.Event
        end

    See the AshSupabase and AshEvents docs for how to define the shared
    `event_log` resource.
    """
  end

  defp missing_event_log_message do
    """
    AshSupabase.Resource requires an `event_log` to be configured in the \
    `events` block (from AshEvents.Events):

        events do
          event_log MyApp.Events.Event
        end

    Without it, AshEvents has nowhere to persist the event half of the \
    dual-table pattern.
    """
  end
end
