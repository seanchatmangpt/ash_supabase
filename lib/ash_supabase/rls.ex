defmodule AshSupabase.Rls do
  @moduledoc """
  Makes Supabase Row Level Security policies work when you talk to Postgres directly.

  Supabase's RLS policies are written against two helper functions, `auth.uid()`
  and `auth.jwt()`, and both of them are thin wrappers over a *connection
  setting*:

      -- roughly what Supabase installs in the auth schema
      create function auth.jwt() returns jsonb as $$
        select coalesce(
          nullif(current_setting('request.jwt.claim', true), ''),
          nullif(current_setting('request.jwt.claims', true), '')
        )::jsonb
      $$ language sql stable;

  PostgREST sets `request.jwt.claims` from the verified access token and then
  switches the connection to the role named in the token's `role` claim, which
  is why the same policy behaves differently for `anon`, `authenticated` and
  `service_role`. Nothing else is going on.

  When you use `AshPostgres` you bypass PostgREST entirely: you connect with
  your own database user, `request.jwt.claims` is never set, `auth.uid()`
  returns `NULL`, and every policy that depends on it silently denies (or, for
  a `BYPASSRLS` role, silently allows) everything. This module closes that gap
  by doing what PostgREST does, from Elixir.

  ## The pieces

    * A process-local claim store (`put_claims/1`, `get_claims/0`,
      `with_claims/2`). `AshSupabase.Plug` fills it from the verified bearer
      token at the top of the request.
    * `set_config_statements/2`, which turns those claims into the exact SQL to
      run. It is a pure function so the interesting decision — which role, which
      claims — is testable without a database.
    * `AshSupabase.Rls.Repo`, a mixin for your `AshPostgres.Repo` that runs
      those statements in `c:AshPostgres.Repo.on_transaction_begin/1`.

  ## Example

      # endpoint / router
      plug AshSupabase.Plug, client: MyApp.Supabase

      # repo
      defmodule MyApp.Repo do
        use AshPostgres.Repo, otp_app: :my_app
        use AshSupabase.Rls.Repo
      end

      # anywhere else, e.g. an Oban worker acting as a specific user
      AshSupabase.Rls.with_claims(%{"sub" => user_id, "role" => "authenticated"}, fn ->
        Ash.read!(MyApp.Blog.Post)
      end)

  ## Where the claims live

  The store is the process dictionary of the calling process, which is the
  right scope: it is exactly the lifetime of one web request or one job, and it
  cannot leak between concurrent requests the way an application-wide setting
  would.

  `get_claims/0` additionally walks `$callers`, so claims set in a request
  process are still found inside a `Task.async/1` started from it — Ash uses
  tasks for concurrent loads, and without this the sub-queries would run as
  `anon`. It does *not* walk `$ancestors`: a long-lived GenServer that happens
  to have been started by a request must not inherit that request's identity.

  ## Trust boundary

  Claims that reach `put_claims/1` are treated as true. `put_token/1` does *not*
  verify signatures. Verifying the token is the caller's job, and
  `AshSupabase.Plug` (via `AshSupabase.Auth.JWT.verify/3`) is where that
  belongs.
  """

  @claims_key :"$ash_supabase_rls_claims"

  @claims_setting "request.jwt.claims"
  @legacy_prefix "request.jwt.claim."

  @default_anon_role "anon"
  @default_authenticated_role "authenticated"

  # Postgres identifiers are at most NAMEDATALEN - 1 = 63 bytes.
  @max_identifier_bytes 63
  @identifier ~r/\A[A-Za-z_][A-Za-z0-9_$]*\z/

  @typedoc """
  A decoded JWT claim set, with string keys, exactly as `auth.jwt()` will see it.
  """
  @type claims :: %{optional(String.t()) => term()}

  @typedoc """
  A statement to execute, as `{sql, parameters}`.

  Parameters are always bound rather than interpolated — see
  `set_config_statements/2`.
  """
  @type statement :: {String.t(), [term()]}

  @doc """
  Stores `claims` for the current process.

  Accepts a claim map with either string or atom keys, an
  `AshSupabase.Auth.Claims` struct (its `:raw` map is used, since that is the
  token as it was actually signed), or `nil`/`%{}` to clear the store.

  Returns `:ok`.
  """
  @spec put_claims(claims() | map() | struct() | nil) :: :ok
  def put_claims(claims) do
    case normalize(claims) do
      nil ->
        clear_claims()

      normalized ->
        Process.put(@claims_key, normalized)
        :ok
    end
  end

  @doc """
  Stores the claims carried by a raw JWT, **without verifying it**.

  > #### This does not authenticate anything {: .warning}
  >
  > The signature is not checked. Anyone can mint a token with
  > `{"role": "service_role"}` in it, and this function will happily believe it.
  > Only call this with a token you have already verified, or in a trusted
  > context such as a script acting on your own behalf. In a web request, use
  > `AshSupabase.Plug`, which verifies with `AshSupabase.Auth.JWT.verify/3`
  > before it gets here.

  Returns the decoded claims, or `{:error, :token_malformed}` if the token is
  not a well-formed JWT.
  """
  @spec put_token(String.t()) :: {:ok, claims()} | {:error, :token_malformed}
  def put_token(token) when is_binary(token) do
    case Joken.peek_claims(token) do
      {:ok, claims} when is_map(claims) ->
        :ok = put_claims(claims)
        {:ok, claims}

      _error ->
        {:error, :token_malformed}
    end
  end

  @doc """
  Returns the claims for the current process, or `nil`.

  Falls back to the claims of the processes in `$callers`, so work handed to a
  `Task` from a request process still runs as that request's user.
  """
  @spec get_claims() :: claims() | nil
  def get_claims do
    case Process.get(@claims_key) do
      nil -> from_callers(Process.get(:"$callers"))
      claims -> claims
    end
  end

  @doc "Removes any claims stored for the current process."
  @spec clear_claims() :: :ok
  def clear_claims do
    Process.delete(@claims_key)
    :ok
  end

  @doc """
  Runs `fun` with `claims` in effect, restoring the previous claims afterwards.

  The restore happens in an `after` block, so it also runs when `fun` raises,
  throws or exits. Nesting is therefore safe:

      Rls.with_claims(admin, fn ->
        Rls.with_claims(user, fn -> Ash.read!(Post) end)
        # admin's claims are back in effect here
      end)

  Returns whatever `fun` returns.
  """
  @spec with_claims(claims() | map() | struct() | nil, (-> result)) :: result when result: term()
  def with_claims(claims, fun) when is_function(fun, 0) do
    previous = Process.get(@claims_key)
    :ok = put_claims(claims)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  @doc """
  Builds the SQL that puts `claims` on the connection.

  Pass the claims (or `nil`) and get back the statements to run, in order, as
  `{sql, params}` tuples:

      iex> AshSupabase.Rls.set_config_statements(%{"sub" => "u1"})
      [
        {"select set_config('request.jwt.claims', $1, true)", [~s({"sub":"u1"})]},
        {~s(set local role "authenticated"), []}
      ]

      iex> AshSupabase.Rls.set_config_statements(nil)
      [
        {"select set_config('request.jwt.claims', $1, true)", [""]},
        {~s(set local role "anon"), []}
      ]

  ## Why `set_config(..., true)` and not `SET LOCAL`

  `SET LOCAL request.jwt.claims = $1` is a syntax error: `SET` takes a literal,
  never a bind parameter. Interpolating a JWT into the statement string instead
  would be a SQL injection hole with attacker-controlled input in it. The
  three-argument `set_config/3` is the parameterizable equivalent, and its
  third argument is `is_local`: `true` scopes the setting to the surrounding
  transaction, so it is discarded on commit or rollback and cannot leak to the
  next checkout of that pooled connection.

  The role is the one thing that cannot be parameterized — `set local role`
  takes an identifier — so the role name is validated against
  `#{inspect(@identifier)}` and quoted. An invalid role name raises
  `ArgumentError`; it can only come from your own configuration or from a claim
  set you chose to trust, never from an unvalidated string reaching the
  database.

  Claims are always written, even when there are none, because a "no claims"
  request must actively clear anything left over. That matters under
  `Ecto.Adapters.SQL.Sandbox`, where every "transaction" is a savepoint inside
  one long-lived transaction and a `SET LOCAL` from an earlier action really is
  still in effect.

  ## Options

    * `:role` - the Postgres role to switch to, overriding the claims. Pass
      `false` or `nil` to leave the connection's role alone.
    * `:authenticated_role` - role for a request that has claims and no `role`
      claim. Defaults to `"authenticated"`.
    * `:anon_role` - role for a request with no claims. Defaults to `"anon"`.
      Set it to `nil` to leave the role untouched for anonymous requests.
    * `:legacy_claim_settings` - also emit one `request.jwt.claim.<name>`
      setting per scalar claim, the shape PostgREST 7 used and which some older
      hand-written policies still read. Defaults to `false`.

  Any option not given here falls back to the application environment:

      config :ash_supabase, :rls, anon_role: "web_anon"

  ## The role comes from the token

  With no `:role` option the role is taken from the `role` claim, which is what
  PostgREST does and what makes a `service_role` token bypass RLS. That is only
  safe because the claims were verified before they got here — a forged token
  with `"role": "service_role"` would otherwise be a complete authorization
  bypass. Pass `role:` explicitly if you would rather your application decide.
  """
  @spec set_config_statements(claims() | map() | struct() | nil, keyword()) :: [statement()]
  def set_config_statements(claims, opts \\ []) do
    claims = normalize(claims)

    [claims_statement(claims)] ++
      legacy_statements(claims, opts) ++
      role_statements(role(claims, opts))
  end

  defp claims_statement(nil), do: {"select set_config('#{@claims_setting}', $1, true)", [""]}

  defp claims_statement(claims),
    do: {"select set_config('#{@claims_setting}', $1, true)", [Jason.encode!(claims)]}

  defp legacy_statements(nil, _opts), do: []

  defp legacy_statements(claims, opts) do
    if opt(opts, :legacy_claim_settings, false) do
      claims
      |> Enum.sort_by(fn {key, _value} -> key end)
      # The setting *name* is interpolated, so only claims whose names are known
      # to be harmless identifiers are emitted at all. Structured claims are
      # skipped: the legacy shape had no representation for them.
      |> Enum.filter(fn {key, value} -> identifier?(key) and scalar?(value) end)
      |> Enum.map(fn {key, value} ->
        {"select set_config('#{@legacy_prefix}#{key}', $1, true)", [to_string(value)]}
      end)
    else
      []
    end
  end

  defp role_statements(nil), do: []
  defp role_statements(role), do: [{~s(set local role "#{validate_role!(role)}"), []}]

  defp role(claims, opts) do
    case Keyword.fetch(opts, :role) do
      {:ok, role} when role in [false, nil] -> nil
      {:ok, role} -> to_string(role)
      :error -> default_role(claims, opts)
    end
  end

  defp default_role(nil, opts), do: opt(opts, :anon_role, @default_anon_role)

  defp default_role(claims, opts) do
    case claims["role"] do
      role when is_binary(role) and role != "" ->
        role

      _absent ->
        opt(opts, :authenticated_role, @default_authenticated_role)
    end
  end

  defp validate_role!(role) do
    if identifier?(role) do
      role
    else
      raise ArgumentError, """
      #{inspect(role)} is not a usable Postgres role name.

      `set local role` takes an identifier, which cannot be sent as a bind \
      parameter, so ash_supabase only accepts names matching \
      #{inspect(@identifier)} and at most #{@max_identifier_bytes} bytes long. \
      If this came from a token's `role` claim, that project is minting tokens \
      ash_supabase will not act on; pass `role:` explicitly to choose the role \
      yourself.\
      """
    end
  end

  defp identifier?(value) when is_binary(value) do
    byte_size(value) <= @max_identifier_bytes and Regex.match?(@identifier, value)
  end

  defp identifier?(_value), do: false

  defp scalar?(value), do: is_binary(value) or is_number(value) or is_boolean(value)

  defp opt(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Keyword.get(app_env(), key, default)
    end
  end

  defp app_env, do: Application.get_env(:ash_supabase, :rls, [])

  defp restore(nil), do: clear_claims()

  defp restore(claims) do
    Process.put(@claims_key, claims)
    :ok
  end

  defp from_callers(callers) when is_list(callers) do
    Enum.find_value(callers, fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} -> Keyword.get(dictionary, @claims_key)
        nil -> nil
      end
    end)
  end

  defp from_callers(_callers), do: nil

  defp normalize(nil), do: nil

  # An `AshSupabase.Auth.Claims` struct keeps the undecoded token in `:raw`,
  # which is what the database should see: the struct's own fields have already
  # been massaged (unix timestamps into `DateTime`, for one) in ways a policy
  # reading `auth.jwt()` would not expect.
  defp normalize(%{raw: raw}) when is_map(raw) and map_size(raw) > 0, do: normalize(raw)

  defp normalize(claims) when is_struct(claims) do
    claims |> Map.from_struct() |> normalize()
  end

  defp normalize(claims) when is_map(claims) and map_size(claims) == 0, do: nil

  defp normalize(claims) when is_map(claims) do
    Map.new(claims, fn {key, value} -> {to_string(key), value} end)
  end
end
