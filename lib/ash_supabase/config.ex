defmodule AshSupabase.Config do
  @moduledoc """
  Resolved connection settings for a single Supabase project.

  A config is normally produced for you by a client module (see
  `AshSupabase.Client`), but it can also be built directly with `new/1` when you
  need to talk to a project that is only known at runtime.

  ## Keys

    * `:url` - the project URL, e.g. `"https://abcdefgh.supabase.co"`. Required.
    * `:api_key` - the key sent in the `apikey` header. This is the *publishable*
      (anon) key for user-scoped access, or the *secret* (service role) key for
      trusted server-side access. Required.
    * `:access_token` - the bearer token sent in `Authorization`. Defaults to
      `:api_key`. Override per request to act as a signed-in user so that Row
      Level Security applies to them.
    * `:schema` - the Postgres schema exposed through the Data API. Defaults to
      `"public"`.
    * `:jwt_secret` - the legacy HS256 signing secret, used by
      `AshSupabase.Auth.JWT` to verify access tokens locally.
    * `:jwks_url` - where to fetch asymmetric (ES256/RS256) signing keys.
      Defaults to `<url>/auth/v1/.well-known/jwks.json`.
    * `:headers` - extra headers merged into every request.
    * `:req_options` - options forwarded to `Req.new/1`. Use this for timeouts,
      retries, or to install a test stub via `plug:`.

  ## Redaction

  The struct implements `Inspect` so that `:api_key`, `:access_token` and
  `:jwt_secret` never leak into logs or crash reports.
  """

  @type t :: %__MODULE__{
          url: String.t(),
          api_key: String.t(),
          access_token: String.t(),
          schema: String.t(),
          jwt_secret: String.t() | nil,
          jwks_url: String.t() | nil,
          headers: [{String.t(), String.t()}],
          req_options: keyword()
        }

  defstruct [
    :url,
    :api_key,
    :access_token,
    :jwt_secret,
    :jwks_url,
    schema: "public",
    headers: [],
    req_options: []
  ]

  @schema [
    url: [
      type: :string,
      required: true,
      doc: "The Supabase project URL, e.g. `https://abcdefgh.supabase.co`."
    ],
    api_key: [
      type: :string,
      required: true,
      doc: "The key sent in the `apikey` header (publishable/anon or secret/service role)."
    ],
    access_token: [
      type: {:or, [:string, nil]},
      doc: "Bearer token for the `Authorization` header. Defaults to `:api_key`."
    ],
    schema: [
      type: :string,
      default: "public",
      doc: "The Postgres schema exposed through the Data API."
    ],
    jwt_secret: [
      type: {:or, [:string, nil]},
      doc: "Legacy HS256 JWT signing secret, for local token verification."
    ],
    jwks_url: [
      type: {:or, [:string, nil]},
      doc:
        "JWKS endpoint for asymmetric signing keys. Defaults to `<url>/auth/v1/.well-known/jwks.json`."
    ],
    headers: [
      type: {:list, {:tuple, [:string, :string]}},
      default: [],
      doc: "Extra headers merged into every request."
    ],
    req_options: [
      type: :keyword_list,
      default: [],
      doc: "Options forwarded to `Req.new/1`."
    ]
  ]

  @doc "The option schema accepted by `new/1`."
  @spec schema() :: keyword()
  def schema, do: @schema

  @doc """
  Builds a config from a keyword list or map.

  Raises `ArgumentError` if required options are missing or malformed.

      iex> config = AshSupabase.Config.new!(url: "https://x.supabase.co", api_key: "anon")
      iex> config.schema
      "public"
  """
  @spec new!(keyword() | map() | t()) :: t()
  def new!(%__MODULE__{} = config), do: config

  def new!(opts) do
    case new(opts) do
      {:ok, config} -> config
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  Builds a config, returning `{:ok, config}` or `{:error, message}`.
  """
  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, String.t()}
  def new(%__MODULE__{} = config), do: {:ok, config}

  def new(opts) when is_map(opts), do: opts |> Map.to_list() |> new()

  def new(opts) when is_list(opts) do
    with {:ok, opts} <- validate(opts) do
      url = normalize_url(opts[:url])

      {:ok,
       %__MODULE__{
         url: url,
         api_key: opts[:api_key],
         access_token: opts[:access_token] || opts[:api_key],
         schema: opts[:schema],
         jwt_secret: opts[:jwt_secret],
         jwks_url: opts[:jwks_url] || default_jwks_url(url),
         headers: normalize_headers(opts[:headers]),
         req_options: opts[:req_options]
       }}
    end
  end

  defp validate(opts) do
    case Spark.Options.validate(opts, @schema) do
      {:ok, opts} -> {:ok, opts}
      {:error, %{__exception__: true} = error} -> {:error, Exception.message(error)}
      {:error, error} -> {:error, inspect(error)}
    end
  end

  @doc """
  Returns a copy of the config that authenticates as `token`.

  Use this to make requests on behalf of a signed-in user so that Row Level
  Security policies evaluate against their claims rather than the anon role.
  """
  @spec with_token(t(), String.t() | nil) :: t()
  def with_token(%__MODULE__{} = config, nil), do: config

  def with_token(%__MODULE__{} = config, token) when is_binary(token),
    do: %{config | access_token: token}

  @doc "The base URL of the PostgREST Data API."
  @spec rest_url(t()) :: String.t()
  def rest_url(%__MODULE__{url: url}), do: url <> "/rest/v1"

  @doc "The base URL of the GoTrue authentication API."
  @spec auth_url(t()) :: String.t()
  def auth_url(%__MODULE__{url: url}), do: url <> "/auth/v1"

  @doc "The base URL of the Storage API."
  @spec storage_url(t()) :: String.t()
  def storage_url(%__MODULE__{url: url}), do: url <> "/storage/v1"

  @doc "The base URL of the Edge Functions API."
  @spec functions_url(t()) :: String.t()
  def functions_url(%__MODULE__{url: url}), do: url <> "/functions/v1"

  @doc """
  The Realtime websocket URL, with the `http` scheme swapped for `ws`.

      iex> AshSupabase.Config.new!(url: "https://x.supabase.co", api_key: "k")
      ...> |> AshSupabase.Config.realtime_url()
      "wss://x.supabase.co/realtime/v1/websocket"
  """
  @spec realtime_url(t()) :: String.t()
  def realtime_url(%__MODULE__{url: url}) do
    url
    |> String.replace_prefix("https://", "wss://")
    |> String.replace_prefix("http://", "ws://")
    |> Kernel.<>("/realtime/v1/websocket")
  end

  defp default_jwks_url(url), do: url <> "/auth/v1/.well-known/jwks.json"

  defp normalize_url(url) when is_binary(url), do: String.trim_trailing(url, "/")

  defp normalize_headers(headers) do
    Enum.map(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(config, opts) do
      redacted = %{
        url: config.url,
        api_key: redact(config.api_key),
        access_token: redact(config.access_token),
        schema: config.schema,
        jwt_secret: redact(config.jwt_secret),
        jwks_url: config.jwks_url,
        headers: config.headers,
        req_options: config.req_options
      }

      concat(["#AshSupabase.Config<", to_doc(redacted, opts), ">"])
    end

    defp redact(nil), do: nil
    defp redact(_), do: "[REDACTED]"
  end
end
