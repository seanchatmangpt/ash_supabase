defmodule AshSupabase.Auth do
  @moduledoc """
  Turn a Supabase-issued JWT into an Ash actor.

  Supabase Auth (GoTrue) issues a JWT for every session. Once PostgREST
  is locked out of writing to your tables (see
  `Mix.Tasks.AshSupabase.GenPolicies`), that token is no longer presented
  to PostgREST at all -- it's presented to *your* Ash-backed application,
  which must turn it into the `actor:` Ash policies authorize against.
  That's what this module does.

  ## Usage

  In a Phoenix (or any Plug-based) app, verify the bearer token once,
  early in the pipeline, and stash the resulting actor for downstream
  Ash calls:

      def call(conn, _opts) do
        with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
             {:ok, actor} <- AshSupabase.Auth.verify(token, jwt_secret()) do
          Ash.PlugHelpers.set_actor(conn, actor)
        else
          _ -> Ash.PlugHelpers.set_actor(conn, nil)
        end
      end

  `actor` is an `AshSupabase.Auth.Actor` struct -- pass it straight as
  the `actor:` option to any Ash call, and reference `actor(:id)` /
  `actor(:role)` in `policies` blocks exactly as in the `Todo` example
  resource.

  ## Which key verifies the token

  Supabase projects sign JWTs one of two ways:

    * **Legacy shared secret (HS256)** -- the project's "JWT Secret"
      from the API settings page. This is what `verify/3` checks by
      default via `AshSupabase.Auth.HS256`.
    * **Asymmetric signing keys (ES256/RS256)**, rotatable, verified
      against the project's JWKS endpoint
      (`https://<project>.supabase.co/auth/v1/.well-known/jwks.json`).
      Implement the `AshSupabase.Auth.Verifier` behaviour against your
      JWKS client of choice and pass it as the `:verifier` option --
      `AshSupabase.Auth` never guesses which algorithm to trust.
  """

  defmodule Actor do
    @moduledoc """
    The actor built from a verified Supabase JWT's claims.

    `id` is the Supabase Auth user id (`sub`) -- the same id stored in
    `auth.users` and, via `persist_actor_primary_key`, in every event an
    action performed by this actor produces. `role` is the Postgres role
    Supabase would have connected as (`anon`, `authenticated`, or
    `service_role`); policies typically gate on `id`, `role`, or both.
    """

    @enforce_keys [:id, :role, :claims]
    defstruct [:id, :role, :email, :claims]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            role: String.t(),
            email: String.t() | nil,
            claims: map()
          }
  end

  @doc """
  Behaviour for a pluggable JWT verifier.

  `AshSupabase.Auth.HS256` is the built-in implementation for Supabase's
  legacy shared-secret projects. Implement this behaviour yourself (e.g.
  backed by a JWKS-fetching library) to support asymmetric signing keys.
  """
  @callback verify(token :: String.t(), key :: term, opts :: keyword) ::
              {:ok, claims :: map} | {:error, reason :: term}

  @default_verifier AshSupabase.Auth.HS256

  @doc """
  Verify `token` and build an `AshSupabase.Auth.Actor` from its claims.

  `key` is passed through to the verifier -- for the default
  `AshSupabase.Auth.HS256` verifier, this is the project's JWT secret
  (a binary).

  ## Options

    * `:verifier` -- module implementing `AshSupabase.Auth` (the
      `verify/3` callback). Defaults to `AshSupabase.Auth.HS256`.
    * `:audience` -- expected `aud` claim. Defaults to `"authenticated"`,
      Supabase's default audience for signed-in users. Pass `nil` to
      skip the check.
  """
  @spec verify(String.t(), term, keyword) :: {:ok, Actor.t()} | {:error, term}
  def verify(token, key, opts \\ []) when is_binary(token) do
    verifier = Keyword.get(opts, :verifier, @default_verifier)
    audience = Keyword.get(opts, :audience, "authenticated")

    with {:ok, claims} <- verifier.verify(token, key, opts),
         :ok <- check_audience(claims, audience) do
      {:ok, actor_from_claims(claims)}
    end
  end

  @doc """
  Build an `AshSupabase.Auth.Actor` directly from an already-verified
  claims map (e.g. if you verify the token with a library of your own
  and just want the Actor shape `AshSupabase` expects).
  """
  @spec actor_from_claims(map) :: Actor.t()
  def actor_from_claims(claims) when is_map(claims) do
    %Actor{
      id: fetch_claim(claims, "sub"),
      role: fetch_claim(claims, "role") || "authenticated",
      email: fetch_claim(claims, "email"),
      claims: claims
    }
  end

  defp check_audience(_claims, nil), do: :ok

  defp check_audience(claims, expected) do
    case fetch_claim(claims, "aud") do
      ^expected -> :ok
      other -> {:error, {:invalid_audience, expected: expected, got: other}}
    end
  end

  defp fetch_claim(claims, key) do
    Map.get(claims, key) || Map.get(claims, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(claims, key)
  end
end

defmodule AshSupabase.Auth.HS256 do
  @moduledoc """
  Verifies a Supabase JWT signed with the project's legacy shared secret
  (HS256), with no third-party JWT dependency.

  Rejects (rather than silently ignoring) anything that isn't exactly
  `HS256` up front, so a token can never talk its way into being
  verified with the wrong algorithm. Signature comparison is constant
  time.
  """

  @behaviour AshSupabase.Auth

  @impl true
  def verify(token, secret, _opts) when is_binary(token) and is_binary(secret) do
    with [header_b64, payload_b64, signature_b64] <- String.split(token, ".", parts: 3),
         {:ok, header} <- decode_segment(header_b64),
         {:ok, "HS256"} <- fetch_alg(header),
         {:ok, signature} <- decode_signature(signature_b64),
         :ok <- verify_signature(header_b64, payload_b64, signature, secret),
         {:ok, claims} <- decode_segment(payload_b64),
         :ok <- check_expiry(claims) do
      {:ok, claims}
    else
      {:ok, other_alg} when is_binary(other_alg) -> {:error, {:unsupported_alg, other_alg}}
      [] -> {:error, :malformed_token}
      {:error, _} = error -> error
    end
  end

  defp fetch_alg(%{"alg" => alg}), do: {:ok, alg}
  defp fetch_alg(_), do: {:error, :missing_alg}

  defp decode_segment(segment) do
    with {:ok, json} <- Base.url_decode64(segment, padding: false),
         {:ok, decoded} <- Jason.decode(json) do
      {:ok, decoded}
    else
      :error -> {:error, :invalid_base64}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp decode_signature(segment) do
    case Base.url_decode64(segment, padding: false) do
      {:ok, sig} -> {:ok, sig}
      :error -> {:error, :invalid_base64}
    end
  end

  defp verify_signature(header_b64, payload_b64, signature, secret) do
    expected = :crypto.mac(:hmac, :sha256, secret, "#{header_b64}.#{payload_b64}")

    if secure_compare(expected, signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp check_expiry(%{"exp" => exp}) when is_integer(exp) do
    if exp > System.system_time(:second) do
      :ok
    else
      {:error, :expired}
    end
  end

  defp check_expiry(_claims), do: {:error, :missing_exp}

  # Constant-time binary comparison -- avoids leaking signature bytes via
  # timing, without pulling in a dependency just for this.
  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    :crypto.hash_equals(left, right)
  end

  defp secure_compare(_left, _right), do: false
end
