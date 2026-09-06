defmodule AshSupabase.Auth do
  @moduledoc """
  Supabase Auth (GoTrue) — sign up, sign in, and manage the signed-in user.

  Every function takes a client as its first argument (a module built with
  `use AshSupabase.Client`, an `AshSupabase.Config`, or a keyword list) and
  returns `{:ok, result}` or `{:error, error}`. Requests go through
  `AshSupabase.Client`, so the project's `apikey` header and `:req_options` —
  including test stubs — apply here too.

  ## The two tokens

  A successful credential exchange returns an `AshSupabase.Auth.Session`:

      {:ok, session} =
        AshSupabase.Auth.sign_in_with_password(MyApp.Supabase,
          email: "user@example.com",
          password: "correct horse battery staple"
        )

  `session.access_token` is a short-lived JWT. Pass it as `:token` on data
  requests so PostgREST evaluates Row Level Security as that user:

      AshSupabase.Client.request(MyApp.Supabase, :get, "/rest/v1/posts",
        token: session.access_token
      )

  `session.refresh_token` is long-lived but **single use**: each call to
  `refresh_session/2` invalidates it and returns a new one, so the result must
  replace whatever you stored. Reusing a spent refresh token is what produces
  the `refresh_token_already_used` error.

  ## Which endpoint returns what

  GoTrue is not uniform, and the return types here mirror that rather than
  papering over it:

    * `sign_up/2` returns a `Session` when email confirmation is disabled and a
      bare `AshSupabase.Auth.User` when the user must confirm first — the same
      response shape Supabase uses to avoid leaking whether an address exists.
    * `sign_in_with_otp/2`, `resend/2` return the decoded body, which is `%{}`
      for email and `%{"message_id" => _}` for SMS.
    * `sign_out/3` and `reset_password_for_email/3` return a bare `:ok`; there is
      no meaningful body to hand back.

  ## Verifying tokens

  Checking a token on every request is a local operation — see
  `AshSupabase.Auth.JWT`. Reach for `get_user/2` only when you need GoTrue to be
  the authority, because a JWT stays valid until it expires even if the user was
  banned in the meantime.

  ## Service-role operations

  Listing, creating and deleting users, inviting people, and generating action
  links live in `AshSupabase.Auth.Admin`, which requires the project's secret
  (service role) key.
  """

  alias AshSupabase.Auth.Session
  alias AshSupabase.Auth.User
  alias AshSupabase.Client
  alias AshSupabase.Config
  alias AshSupabase.Error

  @typedoc """
  Request parameters, as a keyword list or a map.

  Keys are sent to GoTrue verbatim after being converted to strings, so any
  field the endpoint accepts can be passed through even if it is not named in
  these docs. `nil` values are dropped rather than sent as JSON `null`.

  The one rewrite is `:captcha_token`, which is lifted into the
  `gotrue_meta_security` envelope GoTrue expects.
  """
  @type params :: keyword() | map()

  @typedoc "Anything `AshSupabase.Client` accepts as a client."
  @type client :: Client.t()

  @typedoc "An error from the API, the network, or the client configuration."
  @type error :: Error.Request.t() | Error.Transport.t() | Error.Configuration.t()

  @doc """
  Registers a new user.

  Body keys: `email` or `phone`, `password`, `data` (written to the user's
  `user_metadata`), `channel` (`"sms"` or `"whatsapp"`), `code_challenge` and
  `code_challenge_method` for PKCE, and `captcha_token`.

  Returns `{:ok, %AshSupabase.Auth.Session{}}` when the project has email
  confirmation turned off and the user is signed in immediately, and
  `{:ok, %AshSupabase.Auth.User{}}` when a confirmation step is pending. Match on
  the struct rather than assuming one of them:

      case AshSupabase.Auth.sign_up(MyApp.Supabase, email: email, password: password) do
        {:ok, %AshSupabase.Auth.Session{} = session} -> sign_in(session)
        {:ok, %AshSupabase.Auth.User{}} -> tell_them_to_check_their_email()
        {:error, error} -> {:error, error}
      end
  """
  @spec sign_up(client(), params()) :: {:ok, Session.t() | User.t()} | {:error, error()}
  def sign_up(client, params) do
    with {:ok, %{body: body}} <- post(client, "/signup", params) do
      {:ok, session_or_user(body)}
    end
  end

  @doc """
  Signs in with an email (or phone) and password.

  `grant_type=password` is a **query** parameter on `/token`, not a body field —
  GoTrue routes on it before looking at the body.

  Body keys: `email` or `phone`, `password`, and `captcha_token`.

  The returned session may carry a `weak_password` advisory: the credentials
  were correct, but the password should be changed.
  """
  @spec sign_in_with_password(client(), params()) :: {:ok, Session.t()} | {:error, error()}
  def sign_in_with_password(client, params), do: token(client, "password", params)

  @doc """
  Signs in with an OIDC ID token obtained from a native provider SDK.

  Body keys: `id_token`, `provider` (`"google"`, `"apple"`, `"azure"`,
  `"facebook"` or `"keycloak"`), and optionally `nonce`, `access_token`,
  `client_id` and `issuer`.

  This is the flow for a mobile app that ran Google or Apple sign-in natively:
  there is no browser redirect to hand back, only the provider's ID token.
  """
  @spec sign_in_with_id_token(client(), params()) :: {:ok, Session.t()} | {:error, error()}
  def sign_in_with_id_token(client, params), do: token(client, "id_token", params)

  @doc """
  Exchanges a PKCE authorization code for a session.

  Body keys: `auth_code` (the `?code=` parameter your redirect URL received) and
  `code_verifier` (the verifier whose challenge you sent to `authorize_url/3`).
  """
  @spec exchange_code_for_session(client(), params()) :: {:ok, Session.t()} | {:error, error()}
  def exchange_code_for_session(client, params), do: token(client, "pkce", params)

  @doc """
  Sends a magic link or a one-time password.

  Body keys: `email` or `phone`, `channel` (`"sms"` or `"whatsapp"`),
  `create_user` (defaults to true server-side), `data`, `code_challenge`,
  `code_challenge_method`, and `captcha_token`.

  Returns `{:ok, %{}}` for email and `{:ok, %{"message_id" => id}}` for SMS. The
  response is deliberately identical whether or not the address is registered,
  so it cannot be used to enumerate users — and neither can your UI, if it just
  relays this result.

  Whether the recipient gets a clickable link or a numeric code is a project
  email-template setting, not a request parameter. `verify_otp/2` handles both.
  """
  @spec sign_in_with_otp(client(), params()) :: {:ok, map()} | {:error, error()}
  def sign_in_with_otp(client, params) do
    with {:ok, %{body: body}} <- post(client, "/otp", params) do
      {:ok, body_map(body)}
    end
  end

  @doc """
  Signs in anonymously, creating a throwaway user with no credentials.

  Body keys: `data` (written to `user_metadata`) and `captcha_token`.

  The returned session belongs to a real user row with `is_anonymous: true`, so
  Row Level Security works normally and the account can later be upgraded by
  calling `update_user/3` with an email and password. Anonymous sign-ins must be
  enabled for the project, otherwise GoTrue answers
  `anonymous_provider_disabled`.
  """
  @spec sign_in_anonymously(client(), params()) :: {:ok, Session.t()} | {:error, error()}
  def sign_in_anonymously(client, params \\ %{}) do
    with {:ok, %{body: body}} <- post(client, "/signup", params) do
      {:ok, Session.from_json(body_map(body))}
    end
  end

  @doc """
  Verifies a one-time password or an email confirmation token.

  Body keys: `type` (`"signup"`, `"invite"`, `"magiclink"`, `"recovery"`,
  `"email_change"`, `"sms"` or `"phone_change"`) plus either `token` together
  with `email`/`phone`, or `token_hash` on its own.

  `token_hash` is what the emailed link carries, so a server-side confirmation
  route only ever needs `type` and `token_hash`; the six-digit code a user types
  in goes in `token` alongside the address it was sent to.
  """
  @spec verify_otp(client(), params()) :: {:ok, Session.t()} | {:error, error()}
  def verify_otp(client, params) do
    with {:ok, %{body: body}} <- post(client, "/verify", params) do
      {:ok, Session.from_json(body_map(body))}
    end
  end

  @doc """
  Exchanges a refresh token for a fresh session.

  Accepts the refresh token directly or a params map. Refresh tokens are
  single-use: store the session this returns, including its **new** refresh
  token, or the next refresh will fail with `refresh_token_already_used`.

      {:ok, session} = AshSupabase.Auth.refresh_session(MyApp.Supabase, stored_refresh_token)
  """
  @spec refresh_session(client(), String.t() | params()) :: {:ok, Session.t()} | {:error, error()}
  def refresh_session(client, refresh_token) when is_binary(refresh_token),
    do: refresh_session(client, %{"refresh_token" => refresh_token})

  def refresh_session(client, params), do: token(client, "refresh_token", params)

  @doc """
  Revokes the session belonging to `token`.

  `token` is the user's access token, not the project's API key — GoTrue needs
  to know *whose* session to end.

  ## Options

    * `:scope` - `:global` (default server-side; every session for the user),
      `:local` (only this one), or `:others` (every session except this one).

  Returns `:ok`. Clear your stored access and refresh tokens afterwards, except
  under `:others` where the current session deliberately survives.
  """
  @spec sign_out(client(), String.t(), keyword()) :: :ok | {:error, error()}
  def sign_out(client, token, opts \\ []) when is_binary(token) do
    params = if opts[:scope], do: [{"scope", to_string(opts[:scope])}], else: []

    with {:ok, _response} <-
           request(client, :post, "/logout", token: token, params: params, json: %{}) do
      :ok
    end
  end

  @doc """
  Fetches the user that `token` belongs to, straight from GoTrue.

  Unlike `AshSupabase.Auth.JWT.verify/3` this is authoritative — it reflects a
  ban, a deletion or a sign-out that happened after the token was issued — at
  the cost of a round trip per call.
  """
  @spec get_user(client(), String.t()) :: {:ok, User.t()} | {:error, error()}
  def get_user(client, token) when is_binary(token) do
    with {:ok, %{body: body}} <- request(client, :get, "/user", token: token) do
      {:ok, User.from_json(body_map(body))}
    end
  end

  @doc """
  Updates the user that `token` belongs to.

  The method is `PUT`, and the body keys are `email`, `phone`, `password`,
  `nonce`, `data`, `app_metadata` and `channel`.

  `data` writes `user_metadata` — which the user themselves controls, so never
  authorize on it. `app_metadata` is only writable with the service role key;
  from a user token GoTrue rejects it.

  Changing an email or phone starts a confirmation flow rather than applying
  immediately: the new address lands in `new_email`/`new_phone` until it is
  confirmed. When the project requires reauthentication for password changes,
  call `reauthenticate/2` first and pass the emailed `nonce` here.
  """
  @spec update_user(client(), String.t(), params()) :: {:ok, User.t()} | {:error, error()}
  def update_user(client, token, params) when is_binary(token) do
    with {:ok, %{body: body}} <-
           request(client, :put, "/user", token: token, json: encode(params)) do
      {:ok, User.from_json(body_map(body))}
    end
  end

  @doc """
  Sends a password-recovery email.

  ## Options

    * `:redirect_to` - where the emailed link should land.
    * `:code_challenge` / `:code_challenge_method` - PKCE parameters.
    * `:captcha_token` - a CAPTCHA response, when the project requires one.

  Returns `:ok` whether or not the address is registered — GoTrue answers
  identically on purpose. The emailed link verifies with `type: "recovery"`,
  after which you set the new password with `update_user/3`.
  """
  @spec reset_password_for_email(client(), String.t(), params()) :: :ok | {:error, error()}
  def reset_password_for_email(client, email, opts \\ []) when is_binary(email) do
    params = opts |> encode() |> Map.put("email", email)

    with {:ok, _response} <- post(client, "/recover", params) do
      :ok
    end
  end

  @doc """
  Resends a signup confirmation or a change-of-address OTP.

  Body keys: `email` or `phone`, and `type` — one of `"signup"`,
  `"email_change"`, `"sms"` or `"phone_change"`. Note that `"recovery"` is not
  among them; resending a password reset means calling
  `reset_password_for_email/3` again.

  Returns the decoded body, `%{"message_id" => id}` for SMS.
  """
  @spec resend(client(), params()) :: {:ok, map()} | {:error, error()}
  def resend(client, params) do
    with {:ok, %{body: body}} <- post(client, "/resend", params) do
      {:ok, body_map(body)}
    end
  end

  @doc """
  Sends a reauthentication nonce to the user behind `token`.

  Required before `update_user/3` can change a password on projects configured
  with "Secure password change"; the emailed six-digit nonce is then passed as
  the `nonce` key.
  """
  @spec reauthenticate(client(), String.t()) :: :ok | {:error, error()}
  def reauthenticate(client, token) when is_binary(token) do
    with {:ok, _response} <-
           request(client, :post, "/reauthenticate", token: token, json: %{}) do
      :ok
    end
  end

  @doc """
  Builds the URL that starts an OAuth sign-in. Makes no request.

  Redirect the browser here; the provider sends the user back to
  `/auth/v1/callback`, which in turn redirects to your app with either
  `#access_token=...` in the fragment (implicit flow) or `?code=...` (PKCE, which
  you then exchange with `exchange_code_for_session/2`).

  ## Options

    * `:scopes` - a list or a space-separated string of provider scopes.
    * `:redirect_to` - where the callback should send the user afterwards. Must
      be on the project's redirect allow-list.
    * `:invite_token` - accepts an invitation as part of the sign-in.
    * `:code_challenge` / `:code_challenge_method` (`"s256"` or `"plain"`) -
      PKCE parameters.
    * `:query_params` - any further parameters, appended verbatim.

  ## Example

      iex> AshSupabase.Auth.authorize_url(
      ...>   [url: "https://x.supabase.co", api_key: "anon"],
      ...>   :github,
      ...>   scopes: ["read:user", "user:email"],
      ...>   redirect_to: "https://example.com/callback"
      ...> )
      {:ok,
       "https://x.supabase.co/auth/v1/authorize?provider=github&scopes=read%3Auser+user%3Aemail&redirect_to=https%3A%2F%2Fexample.com%2Fcallback"}
  """
  @spec authorize_url(client(), atom() | String.t(), keyword()) ::
          {:ok, String.t()} | {:error, error()}
  def authorize_url(client, provider, opts \\ []) do
    with {:ok, config} <- Client.config(client) do
      {extra, opts} = Keyword.pop(opts, :query_params, [])

      query =
        [{"provider", to_string(provider)}] ++
          authorize_param("scopes", opts[:scopes]) ++
          authorize_param("redirect_to", opts[:redirect_to]) ++
          authorize_param("invite_token", opts[:invite_token]) ++
          authorize_param("code_challenge", opts[:code_challenge]) ++
          authorize_param("code_challenge_method", opts[:code_challenge_method]) ++
          Enum.map(extra, fn {key, value} -> {to_string(key), to_string(value)} end)

      {:ok, Config.auth_url(config) <> "/authorize?" <> URI.encode_query(query)}
    end
  end

  @doc """
  Same as `authorize_url/3` but raises when the client cannot be resolved.
  """
  @spec authorize_url!(client(), atom() | String.t(), keyword()) :: String.t()
  def authorize_url!(client, provider, opts \\ []) do
    case authorize_url(client, provider, opts) do
      {:ok, url} -> url
      {:error, error} -> raise error
    end
  end

  @doc """
  Fetches the project's public auth settings (`GET /auth/v1/settings`).

  Reports which providers are enabled and whether signups are open, which is
  what lets a login page render only the buttons that will actually work.
  """
  @spec settings(client()) :: {:ok, map()} | {:error, error()}
  def settings(client) do
    with {:ok, %{body: body}} <- request(client, :get, "/settings") do
      {:ok, body_map(body)}
    end
  end

  defp authorize_param(_key, nil), do: []

  defp authorize_param("scopes", scopes) when is_list(scopes),
    do: [{"scopes", Enum.join(scopes, " ")}]

  defp authorize_param(key, value), do: [{key, to_string(value)}]

  # `grant_type` selects the flow and is a query parameter: GoTrue dispatches on
  # it before the body is read, so putting it in the body silently fails.
  defp token(client, grant_type, params) do
    with {:ok, %{body: body}} <-
           request(client, :post, "/token",
             params: [{"grant_type", grant_type}],
             json: encode(params)
           ) do
      {:ok, Session.from_json(body_map(body))}
    end
  end

  defp post(client, path, params), do: request(client, :post, path, json: encode(params))

  defp request(client, method, path, opts \\ []) do
    with {:ok, config} <- Client.config(client) do
      Client.request(config, method, Config.auth_url(config) <> path, opts)
    end
  end

  # `/signup` answers with a session when the user is immediately signed in and
  # with a bare user when a confirmation step is pending.
  defp session_or_user(body) do
    body = body_map(body)

    if is_binary(body["access_token"]) do
      Session.from_json(body)
    else
      User.from_json(body)
    end
  end

  defp body_map(body) when is_map(body), do: body
  defp body_map(_body), do: %{}

  defp encode(params) when is_list(params) or is_map(params) do
    params
    |> Enum.reduce(%{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, to_string(key), value)
    end)
    |> lift_captcha_token()
  end

  defp lift_captcha_token(%{"captcha_token" => captcha_token} = params) do
    params
    |> Map.delete("captcha_token")
    |> Map.put("gotrue_meta_security", %{"captcha_token" => captcha_token})
  end

  defp lift_captcha_token(params), do: params
end
