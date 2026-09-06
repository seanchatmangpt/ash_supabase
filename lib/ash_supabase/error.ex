defmodule AshSupabase.Error do
  @moduledoc """
  Errors raised by `ash_supabase`.

  Every error in this module is a `Splode.Error`, which means it composes with
  `Ash.Error` and will be aggregated correctly when returned from a data layer,
  a change, or a generic action.

  The error classes used are:

    * `AshSupabase.Error.Request` (`:invalid`) - the Supabase API rejected the
      request. Carries the HTTP status and the parsed PostgREST/GoTrue error body.
    * `AshSupabase.Error.Transport` (`:unknown`) - the request never completed,
      e.g. DNS failure, connection refused, or timeout.
    * `AshSupabase.Error.Configuration` (`:framework`) - the client or resource is
      misconfigured, e.g. a missing URL or an unknown client module.
    * `AshSupabase.Error.Unsupported` (`:framework`) - the requested operation has
      no equivalent in the Supabase Data API, e.g. a multi-resource transaction.
  """

  defmodule Request do
    @moduledoc """
    The Supabase API responded with a non-success status.

    ## Fields

      * `:status` - the HTTP status code.
      * `:code` - the machine-readable error code. PostgREST returns SQLSTATE
        codes such as `"23505"` (unique violation) or `PGRST`-prefixed codes;
        GoTrue returns codes such as `"invalid_credentials"`.
      * `:supabase_message` - the `message` field from the response body.
      * `:details` / `:hint` - PostgREST diagnostic fields, when present.
      * `:body` - the full parsed response body.
      * `:method` / `:request_path` - the request that failed.
    """
    use Splode.Error,
      fields: [
        :status,
        :code,
        :supabase_message,
        :details,
        :hint,
        :body,
        :method,
        :request_path
      ],
      class: :invalid

    @type t :: %__MODULE__{}

    def message(%{status: status} = error) do
      """
      Supabase request failed with status #{status}#{where(error)}

      #{describe(error)}
      """
      |> String.trim()
    end

    defp where(%{method: nil}), do: ""
    defp where(%{request_path: nil}), do: ""

    defp where(%{method: method, request_path: path}),
      do: " (#{method |> to_string() |> String.upcase()} #{path})"

    defp describe(error) do
      [
        error.code && "code: #{error.code}",
        error.supabase_message && "message: #{error.supabase_message}",
        error.details && "details: #{inspect(error.details)}",
        error.hint && "hint: #{error.hint}"
      ]
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> inspect(error.body)
        parts -> Enum.join(parts, "\n")
      end
    end
  end

  defmodule Transport do
    @moduledoc """
    The HTTP request could not be completed.

    `:reason` holds the underlying exception or term from the HTTP client.
    """
    use Splode.Error, fields: [:reason, :method, :request_path], class: :unknown

    @type t :: %__MODULE__{}

    def message(%{reason: reason} = error) do
      "Could not reach Supabase#{where(error)}: #{format(reason)}"
    end

    defp where(%{method: nil}), do: ""
    defp where(%{request_path: nil}), do: ""

    defp where(%{method: method, request_path: path}),
      do: " (#{method |> to_string() |> String.upcase()} #{path})"

    defp format(%{__exception__: true} = exception), do: Exception.message(exception)
    defp format(other), do: inspect(other)
  end

  defmodule Configuration do
    @moduledoc """
    `ash_supabase` is misconfigured.

    Raised when a client module cannot be resolved, required settings are
    missing, or a resource's `supabase` DSL section is incomplete.
    """
    use Splode.Error, fields: [:message, :resource], class: :framework

    @type t :: %__MODULE__{}

    def message(%{message: message, resource: nil}), do: message

    def message(%{message: message, resource: resource}),
      do: "#{inspect(resource)}: #{message}"
  end

  defmodule Unsupported do
    @moduledoc """
    The requested capability is not available through the Supabase Data API.

    The most common cause is a multi-resource transaction: PostgREST runs every
    request in its own transaction and exposes no way to span several, so
    `AshSupabase.DataLayer` reports `can?(:transact) == false`. See the
    [data layer guide](data-layer.md#limitations) for the full list.
    """
    use Splode.Error, fields: [:feature, :message, :resource], class: :framework

    @type t :: %__MODULE__{}

    def message(%{message: message}) when is_binary(message), do: message

    def message(%{feature: feature, resource: resource}) do
      "#{inspect(resource)} does not support #{inspect(feature)} via the Supabase Data API"
    end
  end

  @doc """
  Builds an `AshSupabase.Error.Request` from a parsed HTTP response.

  Understands both the PostgREST error shape
  (`%{"code" => _, "message" => _, "details" => _, "hint" => _}`) and the GoTrue
  shapes (`%{"error" => _, "error_description" => _}` and
  `%{"error_code" => _, "msg" => _}`), falling back to the raw body.
  """
  @spec request_error(integer(), term(), keyword()) :: Request.t()
  def request_error(status, body, opts \\ []) do
    {code, message, details, hint} = extract(body)

    Request.exception(
      status: status,
      code: code,
      supabase_message: message,
      details: details,
      hint: hint,
      body: body,
      method: opts[:method],
      request_path: opts[:path]
    )
  end

  # PostgREST
  defp extract(%{"message" => message} = body) when is_binary(message) do
    {body["code"], message, body["details"], body["hint"]}
  end

  # GoTrue (newer): %{"error_code" => "invalid_credentials", "msg" => "..."}
  defp extract(%{"msg" => msg} = body) when is_binary(msg) do
    {body["error_code"] || body["code"], msg, nil, nil}
  end

  # GoTrue (OAuth-style): %{"error" => "invalid_grant", "error_description" => "..."}
  defp extract(%{"error" => error} = body) when is_binary(error) do
    {error, body["error_description"] || error, nil, nil}
  end

  # Storage: %{"statusCode" => "404", "error" => "not_found", "message" => "..."}
  defp extract(%{"error" => error}) when is_map(error), do: extract(error)

  defp extract(body), do: {nil, nil, nil, body}
end
