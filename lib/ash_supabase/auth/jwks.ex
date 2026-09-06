defmodule AshSupabase.Auth.JWKS do
  @moduledoc """
  Cache for a Supabase project's JSON Web Key Set.

  Verifying an asymmetric access token needs the project's public keys, which
  live at `GET /auth/v1/.well-known/jwks.json`. Fetching them on every request
  would put an HTTP round trip in front of every authenticated call, so this
  module keeps them in ETS. Supabase serves the endpoint with
  `Cache-Control: public, max-age=600`, and that header is honored: the cache
  entry expires when the CDN's copy does, falling back to 600 seconds when the
  header is absent. A response that asks not to be cached (`max-age=0`, which is
  also what a bare `Plug` test stub sends) is therefore refetched every time —
  set `:ttl` explicitly to override the endpoint.

  ## Starting the cache

  Add it to your supervision tree:

      children = [
        AshSupabase.Auth.JWKS,
        MyAppWeb.Endpoint
      ]

  The process only owns the ETS table. Reads and writes happen in the calling
  process, so a burst of concurrent verifications does not queue behind a single
  GenServer.

  **Starting it is optional.** When the process is not running, `fetch/2` still
  works — it simply performs the HTTP request every time. That keeps a library
  user who forgot the supervision entry slow rather than broken, and keeps tests
  that never start an application working.

  ## Key rotation

  Supabase rotates signing keys by publishing the new key alongside the old one
  and then minting tokens with a new `kid`. A verifier that only ever read a
  cached key set would reject every token for up to the TTL. `AshSupabase.Auth.JWT`
  therefore calls `refresh/2` once when a token's `kid` is not in the cached set,
  and only then gives up.

  ## HS256-only projects

  A project still on the legacy shared secret publishes *no* keys — GoTrue
  deliberately excludes HMAC keys from the endpoint — so `fetch/2` returns
  `{:ok, []}`. That is not an error here; `AshSupabase.Auth.JWT` turns it into a
  message telling you to configure `:jwt_secret`.
  """

  use GenServer

  alias AshSupabase.Client
  alias AshSupabase.Config
  alias AshSupabase.Error

  @table :ash_supabase_jwks

  # Supabase serves `Cache-Control: public, max-age=600` on the JWKS endpoint.
  @default_ttl :timer.seconds(600)

  @typedoc "A public JWK, exactly as published by the project."
  @type key :: %{optional(String.t()) => term()}

  @doc """
  Starts the cache owner process.

  Accepts the standard `:name` option; every other option is ignored.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    {:ok, %{}}
  end

  @doc """
  Returns the project's public keys, from cache when they are still fresh.

  ## Options

    * `:jwks_url` - override the endpoint. Defaults to the config's `:jwks_url`,
      which itself defaults to `<url>/auth/v1/.well-known/jwks.json`.
    * `:ttl` - cache lifetime in milliseconds, overriding the endpoint's
      `Cache-Control` header. `0` disables caching for the call.

  Returns `{:ok, keys}` — possibly an empty list for an HS256-only project — or
  `{:error, error}` if the endpoint could not be read.
  """
  @spec fetch(Client.t(), keyword()) :: {:ok, [key()]} | {:error, Exception.t()}
  def fetch(client, opts \\ []) do
    with {:ok, config} <- Client.config(client) do
      url = resolve_jwks_url(config, opts)

      case cached(url) do
        {:ok, keys} -> {:ok, keys}
        :miss -> load(config, url, opts)
      end
    end
  end

  @doc """
  Fetches the key set from the network, ignoring and then replacing the cache.

  Call this when a token carries a `kid` that the cached set does not contain,
  which is how a key rotation first becomes visible.
  """
  @spec refresh(Client.t(), keyword()) :: {:ok, [key()]} | {:error, Exception.t()}
  def refresh(client, opts \\ []) do
    with {:ok, config} <- Client.config(client) do
      load(config, resolve_jwks_url(config, opts), opts)
    end
  end

  @doc """
  Returns the key whose `kid` matches, or `nil`.

  A token minted by a project with a single signing key may carry no `kid` at
  all. In that case the lone published key is unambiguous and is returned;
  with several keys and no `kid` there is nothing to select on, so this returns
  `nil` rather than guessing.

      iex> keys = [%{"kid" => "a", "kty" => "EC"}, %{"kid" => "b", "kty" => "EC"}]
      iex> AshSupabase.Auth.JWKS.find_key(keys, "b")
      %{"kid" => "b", "kty" => "EC"}
      iex> AshSupabase.Auth.JWKS.find_key(keys, nil)
      nil
      iex> AshSupabase.Auth.JWKS.find_key([%{"kid" => "a"}], nil)
      %{"kid" => "a"}
  """
  @spec find_key([key()], String.t() | nil) :: key() | nil
  def find_key(keys, kid) when is_list(keys) and is_binary(kid),
    do: Enum.find(keys, &(Map.get(&1, "kid") == kid))

  def find_key([key], nil), do: key
  def find_key(keys, nil) when is_list(keys), do: nil

  @doc """
  Drops every cached key set.

  Useful in tests, and after rotating keys out of band.
  """
  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  The JWKS endpoint a given client will read.

      iex> AshSupabase.Auth.JWKS.jwks_url(url: "https://x.supabase.co", api_key: "k")
      {:ok, "https://x.supabase.co/auth/v1/.well-known/jwks.json"}
  """
  @spec jwks_url(Client.t()) :: {:ok, String.t()} | {:error, Exception.t()}
  def jwks_url(client) do
    with {:ok, config} <- Client.config(client) do
      {:ok, resolve_jwks_url(config, [])}
    end
  end

  defp resolve_jwks_url(%Config{} = config, opts) do
    opts[:jwks_url] || config.jwks_url || Config.auth_url(config) <> "/.well-known/jwks.json"
  end

  defp load(%Config{} = config, url, opts) do
    case Client.request(config, :get, url) do
      {:ok, %{body: %{"keys" => keys}, headers: headers}} when is_list(keys) ->
        put(url, keys, ttl(headers, opts))
        {:ok, keys}

      {:ok, %{status: status, body: body}} ->
        {:error,
         Error.Request.exception(
           status: status,
           supabase_message: "expected a JSON object with a \"keys\" list",
           body: body,
           method: :get,
           request_path: url
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp cached(url) do
    with tid when tid != :undefined <- :ets.whereis(@table),
         [{^url, keys, expires_at}] <- :ets.lookup(@table, url),
         true <- System.monotonic_time(:millisecond) < expires_at do
      {:ok, keys}
    else
      _other -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp put(url, keys, ttl) do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {url, keys, System.monotonic_time(:millisecond) + ttl})
    end

    :ok
  rescue
    # The owner process can die between the lookup and the insert.
    ArgumentError -> :ok
  end

  defp ttl(headers, opts) do
    case opts[:ttl] do
      ttl when is_integer(ttl) and ttl >= 0 -> ttl
      _other -> max_age(headers) || @default_ttl
    end
  end

  defp max_age(headers) do
    headers
    |> Map.get("cache-control", [])
    |> Enum.find_value(fn value ->
      case Regex.run(~r/max-age\s*=\s*(\d+)/i, value) do
        [_match, seconds] -> :timer.seconds(String.to_integer(seconds))
        nil -> nil
      end
    end)
  end
end
