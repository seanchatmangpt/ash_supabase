# Authentication

`AshSupabase.Auth` wraps Supabase Auth (GoTrue), and `AshSupabase.Auth.JWT`
verifies the access tokens it issues — locally, against the project's signing
keys, with no round trip per request.

## Signing in

```elixir
{:ok, session} =
  AshSupabase.Auth.sign_in_with_password(MyApp.Supabase, %{
    email: "user@example.com",
    password: "correct horse battery staple"
  })

session.access_token   # the JWT you pass to `with_token/2`
session.refresh_token  # single-use; each refresh returns a new one
session.expires_at     # a DateTime
session.user           # an %AshSupabase.Auth.User{}
```

The full surface:

| Function | Endpoint |
| --- | --- |
| `sign_up/2` | `POST /signup` |
| `sign_in_with_password/2` | `POST /token?grant_type=password` |
| `sign_in_with_id_token/2` | `POST /token?grant_type=id_token` |
| `sign_in_with_otp/2` | `POST /otp` — magic link or SMS |
| `sign_in_anonymously/2` | `POST /signup` with no credentials |
| `verify_otp/2` | `POST /verify` |
| `exchange_code_for_session/2` | `POST /token?grant_type=pkce` |
| `refresh_session/2` | `POST /token?grant_type=refresh_token` |
| `sign_out/3` | `POST /logout` |
| `get_user/2`, `update_user/3` | `GET` / `PUT /user` |
| `reset_password_for_email/3` | `POST /recover` |
| `resend/2`, `reauthenticate/2` | `POST /resend`, `GET /reauthenticate` |
| `authorize_url/3` | builds the `/authorize` URL — makes no request |

`sign_up/2` returns either a `Session` or a bare `User`, mirroring GoTrue: with
email confirmation off you get a session immediately; with it on you get an
unconfirmed user and no tokens.

### OAuth

`authorize_url/3` is a pure function — redirect the browser to it, and handle
the callback with `exchange_code_for_session/2`.

```elixir
url =
  AshSupabase.Auth.authorize_url(MyApp.Supabase, :github,
    redirect_to: url(~p"/auth/callback"),
    scopes: ["read:user", "user:email"]
  )

redirect(conn, external: url)
```

### Admin operations

`AshSupabase.Auth.Admin` covers the service-role endpoints: `list_users/2`,
`get_user_by_id/2`, `create_user/2`, `update_user_by_id/3`, `delete_user/3`,
`invite_user_by_email/3` and `generate_link/2`.

> #### These need the secret key {: .warning}
>
> Pass a client configured with the **secret** (service role) key, or a
> per-request `:token`. That key bypasses Row Level Security entirely, so it must
> never reach a browser and should not be your default client.
>
> ```elixir
> AshSupabase.Auth.Admin.list_users(
>   [url: url, api_key: System.fetch_env!("SUPABASE_SERVICE_ROLE_KEY")]
> )
> ```

## Verifying tokens

```elixir
{:ok, claims} = AshSupabase.Auth.JWT.verify(MyApp.Supabase, token)

claims.sub            # the user id — this is what auth.uid() returns
claims.role           # "authenticated" or "anon"
claims.email
claims.app_metadata   # set by your backend; users cannot change it
claims.user_metadata  # user-editable — never authorize on this
claims.raw            # the undecoded claim map
```

### Both signing schemes are supported

Supabase is migrating from a shared HS256 secret to asymmetric keys. Both work,
and `verify/3` picks the right path from the token's own header:

* **HS256** — verified against `:jwt_secret` from your config. Legacy; Supabase
  describes it as not recommended for production.
* **ES256 / RS256 / EdDSA** — verified against the project's JWKS at
  `/auth/v1/.well-known/jwks.json`, selecting the key by the token's `kid`.
  `AshSupabase.Auth.JWKS` caches the response for the lifetime the server's
  `Cache-Control` header specifies (Supabase sends 600 seconds), and refreshes
  once on an unrecognised `kid` so key rotation is handled without a restart.

The two paths never cross: an `HS*` header only ever reaches the shared secret,
and an asymmetric header only ever reaches a JWKS key. That is what closes the
[algorithm-confusion](https://auth0.com/blog/critical-vulnerabilities-in-json-web-token-libraries/)
attack, where an attacker signs a token with a public key as if it were an HMAC
secret.

An HS256-only project publishes an empty JWKS (`{"keys": []}`), by design —
HMAC keys are never exported. If you see an error saying so, configure
`:jwt_secret`.

### Validating issuer and audience

Not checked unless you ask, because the right values depend on your deployment:

```elixir
AshSupabase.Auth.JWT.verify(MyApp.Supabase, token,
  issuer: "https://abcdefgh.supabase.co/auth/v1",
  audience: "authenticated"
)
```

### Reading a token without verifying it

`peek_claims/1` and `peek_header/1` decode without checking the signature. They
are for diagnostics and for routing on `kid` — **never** for authorization. A
token's claims are attacker-controlled until the signature is verified.

## In a Phoenix application

```elixir
pipeline :api do
  plug :accepts, ["json"]
  plug AshSupabase.Plug, client: MyApp.Supabase
end
```

The plug reads the bearer token, verifies it, and assigns:

* `conn.assigns.supabase_claims` — the verified `%AshSupabase.Auth.Claims{}`
* `conn.assigns.current_user` — an actor built from them, for `Ash.read!(actor: ...)`
* `conn.assigns.supabase_token` — the raw token, for `with_token/2`

Options: `:claims_assign` and `:user_assign` rename the assigns; `:user` takes a
1-arity function to build your own actor; `:verify` forwards options to
`verify/3`; `:put_claims` also populates `AshSupabase.Rls`; and `:on_error`
chooses what happens without a usable token:

```elixir
# Public endpoints where signed-in is optional:
plug AshSupabase.Plug, client: MyApp.Supabase, on_error: :continue
```

`:halt` (the default) sends a 401 with a deliberately reason-free body — telling
a caller *why* their token failed is free reconnaissance. Read the reason
server-side with `AshSupabase.Plug.error_reason/1`.

### Building your own actor

By default the actor is the claims struct. To load a real record instead:

```elixir
plug AshSupabase.Plug,
  client: MyApp.Supabase,
  user: fn claims -> Ash.get!(MyApp.Accounts.User, claims.sub, authorize?: false) end
```

That is one query per request — consider whether the claims alone are enough.
`sub`, `role`, `email` and `app_metadata` are already there and already signed.

## Sessions and refresh

Access tokens are short-lived (an hour by default) and refresh tokens are
single-use: each refresh returns a new one, and reusing an old one is treated as
theft. Store the newest pair and check before use:

```elixir
session =
  if AshSupabase.Auth.Session.expired?(session) do
    {:ok, fresh} = AshSupabase.Auth.refresh_session(MyApp.Supabase, session.refresh_token)
    fresh
  else
    session
  end
```

`expired?/2` fails **closed**: a session with no `expires_at` is reported
expired rather than assumed valid.
