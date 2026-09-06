defmodule AshSupabase.Auth.Claims do
  @moduledoc """
  The claim set carried by a Supabase access token.

  Supabase mints these in GoTrue's `AccessTokenClaims`: the registered JWT
  claims (`sub`, `aud`, `exp`, `iat`, `iss`) plus the fields Row Level Security
  policies read back through `auth.jwt()`.

  Three claims are `omitempty` and are therefore absent from tokens minted
  without a session — some admin and service tokens — so treat `session_id`,
  `aal` and `amr` as optional. `email`, `phone`, `role`, `app_metadata`,
  `user_metadata` and `is_anonymous` are always present, though `email` and
  `phone` are empty strings when unset.

  As with `AshSupabase.Auth.User`, `user_metadata` is user-writable and must not
  be used for authorization; `app_metadata` requires the service role key and is
  the claim to branch on.

  `raw` keeps the undecoded claim map, which is where OAuth-server-only claims
  such as `client_id` and `scope` remain reachable.
  """

  alias AshSupabase.Auth.Timestamp

  @typedoc """
  An entry in the `amr` (authentication methods references) claim.

  GoTrue emits `%{"method" => "password", "timestamp" => 1_757_749_466}` with an
  optional `"provider"` for SSO, most recent first. Older tokens used bare
  strings, which are passed through unchanged.
  """
  @type amr_entry :: map() | String.t()

  @typedoc "A verified Supabase access token's claims."
  @type t :: %__MODULE__{
          sub: String.t() | nil,
          aud: String.t() | [String.t()] | nil,
          exp: DateTime.t() | nil,
          iat: DateTime.t() | nil,
          iss: String.t() | nil,
          role: String.t() | nil,
          email: String.t() | nil,
          phone: String.t() | nil,
          app_metadata: map(),
          user_metadata: map(),
          session_id: String.t() | nil,
          aal: String.t() | nil,
          amr: [amr_entry()] | nil,
          is_anonymous: boolean(),
          raw: %{optional(String.t()) => term()}
        }

  defstruct [
    :sub,
    :aud,
    :exp,
    :iat,
    :iss,
    :role,
    :email,
    :phone,
    :session_id,
    :aal,
    :amr,
    app_metadata: %{},
    user_metadata: %{},
    is_anonymous: false,
    raw: %{}
  ]

  @doc """
  Builds a claim struct from a decoded claim map.

  `exp` and `iat` arrive as unix seconds and are converted to `DateTime` for
  consistency with `AshSupabase.Auth.Session`.

      iex> claims = AshSupabase.Auth.Claims.from_map(%{"sub" => "u1", "exp" => 1_757_753_066})
      iex> {claims.sub, claims.exp}
      {"u1", ~U[2025-09-13 08:44:26Z]}
  """
  @spec from_map(map()) :: t()
  def from_map(claims) when is_map(claims) do
    %__MODULE__{
      sub: claims["sub"],
      aud: claims["aud"],
      exp: Timestamp.from_unix(claims["exp"]),
      iat: Timestamp.from_unix(claims["iat"]),
      iss: claims["iss"],
      role: claims["role"],
      email: claims["email"],
      phone: claims["phone"],
      app_metadata: claims["app_metadata"] || %{},
      user_metadata: claims["user_metadata"] || %{},
      session_id: claims["session_id"],
      aal: claims["aal"],
      amr: claims["amr"],
      is_anonymous: claims["is_anonymous"] || false,
      raw: claims
    }
  end
end

defmodule AshSupabase.Auth.JWT do
  @moduledoc """
  Local verification of Supabase access tokens.

  Calling `GET /auth/v1/user` on every request turns each API call into two, and
  couples your latency to Supabase's. Access tokens are signed JWTs, so a server
  holding the project's key material can answer "who is this?" without leaving
  the BEAM. That is what this module does, and it is the right default for
  authenticating requests in a Phoenix pipeline.

  It still gets you a *stale* answer: a token stays cryptographically valid until
  `exp` even if the user was banned or signed out a minute ago. When that matters
  — deleting an account, changing a password — call `AshSupabase.Auth.get_user/2`
  and let GoTrue be the authority.

  ## Both signing schemes

  Supabase projects sign with one of two schemes, and this module supports both,
  choosing between them from the token's own `alg` header:

    * **HS256** with the legacy shared JWT secret. Configure it as `:jwt_secret`
      on the client. Symmetric, which means anything that can verify a token can
      also mint one — Supabase does not recommend it for new projects.
    * **ES256, RS256 or EdDSA** with the project's asymmetric signing keys. The
      public keys come from the project's JWKS endpoint (see
      `AshSupabase.Auth.JWKS`) and are selected by the token's `kid` header. No
      secret is stored in your application at all.

  The two paths never cross: an `HS*` token is never verified against a JWKS key
  and an asymmetric token is never verified against the shared secret, which is
  what closes the classic algorithm-confusion attack. A published key that
  declares its own `alg` must additionally agree with the token's header.

  ## Example

      config :my_app, MyApp.Supabase,
        url: "https://abcdefgh.supabase.co",
        api_key: System.fetch_env!("SUPABASE_ANON_KEY")

      {:ok, claims} =
        AshSupabase.Auth.JWT.verify(MyApp.Supabase, token,
          issuer: "https://abcdefgh.supabase.co/auth/v1",
          audience: "authenticated"
        )

      claims.sub          #=> "123e4567-e89b-12d3-a456-426614174000"
      claims.role         #=> "authenticated"

  `issuer` and `audience` are checked only when you supply them. Supabase issues
  `iss` as `<project url>/auth/v1` and `aud` as `"authenticated"`, and pinning
  both is worth doing: it stops a token minted by a *different* Supabase project
  from being accepted by yours.
  """

  alias AshSupabase.Auth.Claims
  alias AshSupabase.Auth.JWKS
  alias AshSupabase.Client
  alias AshSupabase.Config
  alias AshSupabase.Error

  @hmac_algorithms ~w(HS256 HS384 HS512)

  @typedoc """
  Why verification failed.

  `AshSupabase.Error.Configuration` means the *project* is not set up for the
  token it was handed — no `:jwt_secret` for an HS256 token, or an empty key set
  for an asymmetric one. Everything else is a property of the token itself.
  """
  @type reason ::
          :token_malformed
          | :signature_error
          | :token_expired
          | :token_not_yet_valid
          | :missing_exp
          | {:unknown_kid, String.t() | nil}
          | {:unsupported_algorithm, String.t()}
          | {:algorithm_mismatch, String.t(), String.t()}
          | {:invalid_issuer, term()}
          | {:invalid_audience, term()}
          | Error.Configuration.t()
          | Error.Request.t()
          | Error.Transport.t()

  @doc """
  Verifies `token` against the project's key material and validates its claims.

  ## Options

    * `:issuer` - expected `iss`, or a list of acceptable issuers. Not checked
      when omitted.
    * `:audience` - expected `aud`, or a list of acceptable audiences. Matches
      when the token's `aud` (string or list) intersects. Not checked when
      omitted.
    * `:leeway` - seconds of clock skew tolerated on `exp` and `nbf`.
      Defaults to `0`.
    * `:now` - unix seconds or a `DateTime` to validate against, for tests.
    * `:jwks_url` / `:ttl` - forwarded to `AshSupabase.Auth.JWKS.fetch/2`.

  On an unknown `kid` the key set is refreshed once — that is how a rotated
  signing key is picked up before its cache entry would have expired — and the
  token is rejected if it is still unknown.
  """
  @spec verify(Client.t(), String.t(), keyword()) :: {:ok, Claims.t()} | {:error, reason()}
  def verify(client, token, opts \\ []) when is_binary(token) do
    with {:ok, config} <- Client.config(client),
         {:ok, header} <- peek_header(token),
         {:ok, signer} <- signer(config, header, opts),
         {:ok, claims} <- verify_signature(token, signer),
         :ok <- validate(claims, opts) do
      {:ok, Claims.from_map(claims)}
    end
  end

  @doc """
  Decodes a token's claims **without verifying its signature**.

  Unsafe by construction: anybody can craft a token with any claims they like,
  and this function will happily decode it. Never authorize on the result. It
  exists for the legitimate cases where you need to look before you can verify —
  reading `sub` to pick a tenant's key set, or logging why a token was rejected.

      iex> {:ok, claims} = AshSupabase.Auth.JWT.peek_claims(
      ...>   "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1MSJ9.5A7pWiGiiK1LAyD25BOhQylhH3nrgAe0Fh2P2hDA3XU"
      ...> )
      iex> claims["sub"]
      "u1"
  """
  @spec peek_claims(String.t()) :: {:ok, map()} | {:error, :token_malformed}
  def peek_claims(token) when is_binary(token) do
    case Joken.peek_claims(token) do
      {:ok, claims} -> {:ok, claims}
      {:error, _reason} -> {:error, :token_malformed}
    end
  end

  @doc """
  Decodes a token's JOSE header **without verifying its signature**.

  Same caveat as `peek_claims/1`. The header is what `verify/3` itself reads
  first, to learn which algorithm and which `kid` to verify against.

      iex> {:ok, header} = AshSupabase.Auth.JWT.peek_header(
      ...>   "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1MSJ9.5A7pWiGiiK1LAyD25BOhQylhH3nrgAe0Fh2P2hDA3XU"
      ...> )
      iex> header["alg"]
      "HS256"
  """
  @spec peek_header(String.t()) :: {:ok, map()} | {:error, :token_malformed}
  def peek_header(token) when is_binary(token) do
    case Joken.peek_header(token) do
      {:ok, header} -> {:ok, header}
      {:error, _reason} -> {:error, :token_malformed}
    end
  end

  defp signer(%Config{} = config, %{"alg" => alg}, _opts) when alg in @hmac_algorithms do
    case config.jwt_secret do
      secret when is_binary(secret) and secret != "" ->
        build_signer(alg, secret)

      _missing ->
        {:error,
         Error.Configuration.exception(
           message: """
           This token is signed with #{alg}, the legacy symmetric algorithm, but no \
           `:jwt_secret` is configured. Copy the project's JWT secret from the \
           Supabase dashboard (Project Settings -> API -> JWT Settings) into your \
           client config as `jwt_secret:`, or migrate the project to asymmetric \
           signing keys so that tokens can be verified from the public JWKS.\
           """
         )}
    end
  end

  defp signer(%Config{} = config, %{"alg" => alg} = header, opts) when is_binary(alg) do
    kid = header["kid"]

    with {:ok, keys} <- JWKS.fetch(config, opts) do
      case JWKS.find_key(keys, kid) do
        nil -> retry_after_refresh(config, alg, kid, opts)
        key -> build_signer(alg, key)
      end
    end
  end

  defp signer(%Config{}, _header, _opts), do: {:error, :token_malformed}

  # An unknown `kid` is the normal first symptom of a key rotation, so the cache
  # gets exactly one chance to catch up before the token is rejected.
  defp retry_after_refresh(config, alg, kid, opts) do
    with {:ok, keys} <- JWKS.refresh(config, opts) do
      case JWKS.find_key(keys, kid) do
        nil -> {:error, no_key_error(keys, kid)}
        key -> build_signer(alg, key)
      end
    end
  end

  defp no_key_error([], _kid) do
    Error.Configuration.exception(
      message: """
      The project's JWKS endpoint published no keys, which is what a project \
      still using the legacy HS256 shared secret returns — GoTrue never exposes \
      HMAC keys. Configure `jwt_secret:` on the client to verify those tokens, \
      or enable asymmetric signing keys for the project.\
      """
    )
  end

  defp no_key_error(_keys, kid), do: {:unknown_kid, kid}

  # A published key that names its own algorithm must agree with the token's
  # header: without this check a key intended for one algorithm could be used to
  # verify a token claiming another.
  defp build_signer(alg, key) when is_map(key) do
    case Map.get(key, "alg") do
      nil -> create_signer(alg, key)
      ^alg -> create_signer(alg, key)
      other -> {:error, {:algorithm_mismatch, alg, other}}
    end
  end

  defp build_signer(alg, secret), do: create_signer(alg, secret)

  defp create_signer(alg, key) do
    {:ok, Joken.Signer.create(alg, key)}
  rescue
    _exception -> {:error, {:unsupported_algorithm, alg}}
  end

  defp verify_signature(token, signer) do
    case Joken.Signer.verify(token, signer) do
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      _error -> {:error, :signature_error}
    end
  rescue
    _exception -> {:error, :signature_error}
  end

  defp validate(claims, opts) do
    now = now(opts)
    leeway = Keyword.get(opts, :leeway, 0)

    with :ok <- validate_exp(claims["exp"], now, leeway),
         :ok <- validate_nbf(claims["nbf"], now, leeway),
         :ok <- validate_issuer(claims["iss"], opts[:issuer]) do
      validate_audience(claims["aud"], opts[:audience])
    end
  end

  defp validate_exp(exp, now, leeway) when is_number(exp) do
    if now < exp + leeway, do: :ok, else: {:error, :token_expired}
  end

  defp validate_exp(_exp, _now, _leeway), do: {:error, :missing_exp}

  defp validate_nbf(nil, _now, _leeway), do: :ok

  defp validate_nbf(nbf, now, leeway) when is_number(nbf) do
    if now >= nbf - leeway, do: :ok, else: {:error, :token_not_yet_valid}
  end

  defp validate_nbf(_nbf, _now, _leeway), do: :ok

  defp validate_issuer(_iss, nil), do: :ok

  defp validate_issuer(iss, expected) do
    if iss in List.wrap(expected), do: :ok, else: {:error, {:invalid_issuer, iss}}
  end

  defp validate_audience(_aud, nil), do: :ok

  defp validate_audience(aud, expected) do
    # `aud` is a plain string on Supabase tokens (GoTrue sets
    # `MarshalSingleStringAsArray = false`), but the JWT spec allows a list.
    if Enum.any?(List.wrap(aud), &(&1 in List.wrap(expected))) do
      :ok
    else
      {:error, {:invalid_audience, aud}}
    end
  end

  defp now(opts) do
    case opts[:now] do
      %DateTime{} = datetime -> DateTime.to_unix(datetime)
      seconds when is_integer(seconds) -> seconds
      _other -> System.system_time(:second)
    end
  end
end
