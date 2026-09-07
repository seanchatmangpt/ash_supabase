defmodule AshSupabase.Client do
  @moduledoc """
  Defines a Supabase client module and executes requests against it.

  ## Defining a client

      defmodule MyApp.Supabase do
        use AshSupabase.Client, otp_app: :my_app
      end

  with configuration read at runtime from the application environment:

      # config/runtime.exs
      config :my_app, MyApp.Supabase,
        url: System.fetch_env!("SUPABASE_URL"),
        api_key: System.fetch_env!("SUPABASE_ANON_KEY"),
        jwt_secret: System.get_env("SUPABASE_JWT_SECRET")

  You can also override `c:config/0` directly, which is useful when settings
  come from somewhere other than the application environment:

      defmodule MyApp.Supabase do
        use AshSupabase.Client

        @impl true
        def config do
          [url: Vault.fetch!("supabase_url"), api_key: Vault.fetch!("supabase_key")]
        end
      end

  ## Making requests

  Most of the time you will use the higher-level modules
  (`AshSupabase.PostgREST`, `AshSupabase.Auth`, `AshSupabase.Storage`) rather
  than calling this module directly. When you do need a raw request:

      AshSupabase.Client.request(MyApp.Supabase, :get, "/rest/v1/posts",
        params: [select: "*", "id" => "eq.1"]
      )

  ## Acting as a user

  Pass `:token` to authenticate as a signed-in user so that Row Level Security
  policies evaluate against their claims:

      AshSupabase.Client.request(MyApp.Supabase, :get, "/rest/v1/posts", token: user_jwt)

  ## Testing

  Set `:req_options` to install a `Req.Test` stub. See the
  [testing guide](testing.md).

      config :my_app, MyApp.Supabase,
        url: "http://localhost",
        api_key: "test",
        req_options: [plug: {Req.Test, MyApp.Supabase}]
  """

  alias AshSupabase.Config
  alias AshSupabase.Error

  @typedoc "A client module, a `AshSupabase.Config`, or a keyword list of settings."
  @type t :: module() | Config.t() | keyword()

  @typedoc "The parsed body and headers of a successful response."
  @type response :: %{status: integer(), body: term(), headers: %{String.t() => [String.t()]}}

  @doc "Returns the client's settings as a keyword list."
  @callback config() :: keyword()

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour AshSupabase.Client

      @otp_app opts[:otp_app]

      @impl AshSupabase.Client
      def config do
        if @otp_app do
          Application.get_env(@otp_app, __MODULE__, [])
        else
          raise AshSupabase.Error.Configuration.exception(
                  message: """
                  #{inspect(__MODULE__)} was defined without `:otp_app`, so it must \
                  implement `config/0` itself.
                  """
                )
        end
      end

      defoverridable config: 0

      @doc """
      Returns the resolved `AshSupabase.Config` for this client.

      Raises if the configuration is missing or invalid.
      """
      @spec supabase_config() :: AshSupabase.Config.t()
      def supabase_config, do: AshSupabase.Client.config!(__MODULE__)
    end
  end

  @doc """
  Resolves any accepted client reference into an `AshSupabase.Config`.

  Accepts a client module, an existing config, or a keyword list.
  """
  @spec config(t()) :: {:ok, Config.t()} | {:error, Error.Configuration.t()}
  def config(%Config{} = config), do: {:ok, config}

  def config(module) when is_atom(module) and not is_nil(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error,
         Error.Configuration.exception(
           message: "#{inspect(module)} is not a loaded module. Is it spelled correctly?"
         )}

      not function_exported?(module, :config, 0) ->
        {:error,
         Error.Configuration.exception(
           message: """
           #{inspect(module)} does not implement `config/0`. Did you forget \
           `use AshSupabase.Client, otp_app: :your_app`?
           """
         )}

      true ->
        case Config.new(module.config()) do
          {:ok, config} ->
            {:ok, config}

          {:error, message} ->
            {:error,
             Error.Configuration.exception(
               message: "invalid configuration for #{inspect(module)}: #{message}"
             )}
        end
    end
  end

  def config(opts) when is_list(opts) do
    case Config.new(opts) do
      {:ok, config} -> {:ok, config}
      {:error, message} -> {:error, Error.Configuration.exception(message: message)}
    end
  end

  def config(other) do
    {:error,
     Error.Configuration.exception(
       message: """
       Expected a client module, an `AshSupabase.Config`, or a keyword list, got: \
       #{inspect(other)}
       """
     )}
  end

  @doc """
  Same as `config/1` but raises on failure.
  """
  @spec config!(t()) :: Config.t()
  def config!(client) do
    case config(client) do
      {:ok, config} -> config
      {:error, error} -> raise error
    end
  end

  @doc """
  Performs a request against the Supabase project.

  `path` is appended to the project URL and should include the API prefix, e.g.
  `"/rest/v1/posts"`. Absolute URLs are used as-is.

  ## Options

    * `:params` - query parameters. Accepts a keyword list or map. String keys
      are preserved verbatim, which matters for PostgREST filters where the key
      is a column name.
    * `:json` - a term to encode as a JSON request body.
    * `:body` - a raw request body, used instead of `:json`.
    * `:headers` - additional headers for this request.
    * `:token` - bearer token overriding the client's `:access_token`.
    * `:schema` - Postgres schema for this request, sent as `Accept-Profile`
      (reads) or `Content-Profile` (writes).
    * `:decode_body` - set to `false` to receive the raw body. Defaults to `true`.
    * `:req_options` - extra options merged into the `Req` request.

  Returns `{:ok, %{status: status, body: body, headers: headers}}` for 2xx
  responses, and `{:error, error}` otherwise. `headers` is a map of downcased
  header name to a list of values.
  """
  @spec request(t(), atom(), String.t(), keyword()) ::
          {:ok, response()}
          | {:error, Error.Request.t() | Error.Transport.t() | Error.Configuration.t()}
  def request(client, method, path, opts \\ []) do
    with {:ok, config} <- config(client) do
      config
      |> Config.with_token(opts[:token])
      |> do_request(method, path, opts)
    end
  end

  @doc """
  Same as `request/4` but raises on failure.
  """
  @spec request!(t(), atom(), String.t(), keyword()) :: response()
  def request!(client, method, path, opts \\ []) do
    case request(client, method, path, opts) do
      {:ok, response} -> response
      {:error, error} -> raise error
    end
  end

  defp do_request(%Config{} = config, method, path, opts) do
    url = absolute_url(config, path)

    req_options =
      config.req_options
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> Keyword.merge(
        method: method,
        url: url,
        headers: headers(config, method, opts),
        decode_body: false
      )
      |> put_params(opts[:params])
      |> put_body(opts)

    case safe_run(req_options) do
      {:ok, %Req.Response{} = response} ->
        handle_response(response, method, path, opts)

      {:error, reason} ->
        {:error, Error.Transport.exception(reason: reason, method: method, request_path: path)}
    end
  end

  defp safe_run(req_options) do
    Req.request(Req.new(req_options))
  rescue
    exception -> {:error, exception}
  end

  defp handle_response(%Req.Response{status: status} = response, _method, _path, opts)
       when status in 200..299 do
    body =
      if Keyword.get(opts, :decode_body, true) do
        decode(response)
      else
        response.body
      end

    {:ok, %{status: status, body: body, headers: normalize_headers(response.headers)}}
  end

  defp handle_response(%Req.Response{status: status} = response, method, path, _opts) do
    {:error, Error.request_error(status, decode(response), method: method, path: path)}
  end

  defp decode(%Req.Response{body: body} = response) do
    if json?(response) do
      case body do
        "" -> nil
        nil -> nil
        binary when is_binary(binary) -> decode_json(binary)
        already_decoded -> already_decoded
      end
    else
      body
    end
  end

  defp decode_json(binary) do
    case Jason.decode(binary) do
      {:ok, decoded} -> decoded
      {:error, _} -> binary
    end
  end

  defp json?(%Req.Response{} = response) do
    response
    |> Req.Response.get_header("content-type")
    |> Enum.any?(&String.contains?(&1, "json"))
  end

  # `apikey`, `authorization` and the profile header are computed from the
  # config and the per-request options, so they are applied last and win. A
  # stale `authorization` in a client's `:headers` silently defeating a
  # per-request `:token` would run the request as the wrong user.
  @reserved_headers ~w(apikey authorization accept-profile content-profile)

  defp headers(config, method, opts) do
    computed = [
      {"apikey", config.api_key},
      {"authorization", "Bearer " <> config.access_token},
      {profile_header(method), Keyword.get(opts, :schema) || config.schema}
    ]

    config.headers
    |> Kernel.++(normalize_request_headers(Keyword.get(opts, :headers, [])))
    |> Enum.reject(fn {key, _value} -> key in @reserved_headers end)
    |> Kernel.++(computed)
    # Later entries win, so a per-request header overrides a configured one.
    |> Enum.reduce(%{}, fn {key, value}, acc -> Map.put(acc, String.downcase(key), value) end)
    |> Enum.to_list()
  end

  # Reads select a schema with `Accept-Profile`; writes use `Content-Profile`.
  defp profile_header(method) when method in [:get, :head], do: "accept-profile"
  defp profile_header(_), do: "content-profile"

  defp normalize_request_headers(headers) when is_map(headers),
    do: headers |> Map.to_list() |> normalize_request_headers()

  defp normalize_request_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {key, value} -> {String.downcase(to_string(key)), to_string(value)} end)
  end

  # Req normalizes response headers to `%{downcased_name => [value]}` before we
  # ever see them, so there is nothing left to do here.
  defp normalize_headers(headers) when is_map(headers), do: headers

  defp put_params(req_options, nil), do: req_options
  defp put_params(req_options, []), do: req_options
  defp put_params(req_options, params), do: Keyword.put(req_options, :params, params)

  defp put_body(req_options, opts) do
    cond do
      Keyword.has_key?(opts, :body) -> Keyword.put(req_options, :body, opts[:body])
      Keyword.has_key?(opts, :json) -> Keyword.put(req_options, :json, opts[:json])
      true -> req_options
    end
  end

  defp absolute_url(_config, "http://" <> _ = url), do: url
  defp absolute_url(_config, "https://" <> _ = url), do: url
  defp absolute_url(%Config{url: base}, "/" <> _ = path), do: base <> path
  defp absolute_url(%Config{url: base}, path), do: base <> "/" <> path
end
