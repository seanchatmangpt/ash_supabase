# AshSupabase

[![Hex.pm](https://img.shields.io/hexpm/v/ash_supabase.svg)](https://hex.pm/packages/ash_supabase)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ash_supabase)
[![License](https://img.shields.io/hexpm/l/ash_supabase.svg)](LICENSE)

Supabase integration for the [Ash Framework](https://ash-hq.org).

`ash_supabase` gives you a **PostgREST-backed Ash data layer**, **GoTrue
authentication** with local JWT verification, **Storage**, **Realtime**, and
helpers that make **Postgres Row Level Security** work when you reach the
database through `AshPostgres` instead.

```elixir
defmodule MyApp.Blog.Post do
  use Ash.Resource, domain: MyApp.Blog, data_layer: AshSupabase.DataLayer

  supabase do
    table "posts"
    client MyApp.Supabase
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
    attribute :status, :atom, constraints: [one_of: [:draft, :published]], public?: true
    create_timestamp :inserted_at
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
```

```elixir
MyApp.Blog.Post
|> Ash.Query.filter(status == :published and views > 100)
|> Ash.Query.sort(inserted_at: :desc)
|> Ash.Query.limit(10)
|> AshSupabase.DataLayer.with_token(conn.assigns.supabase_token)
|> Ash.read!()
```

That query becomes one request, with Row Level Security evaluated as the
signed-in user:

```http
GET /rest/v1/posts?status=eq.published&views=gt.100&order=inserted_at.desc&limit=10
apikey: <publishable key>
Authorization: Bearer <user access token>
Accept-Profile: public
```

## Installation

```elixir
def deps do
  [
    {:ash, "~> 3.33"},
    {:ash_supabase, "~> 0.1"}
  ]
end
```

Then run the installer:

```bash
mix ash_supabase.install
```

Or wire it up by hand — define a client module:

```elixir
defmodule MyApp.Supabase do
  use AshSupabase.Client, otp_app: :my_app
end
```

```elixir
# config/runtime.exs
config :my_app, MyApp.Supabase,
  url: System.fetch_env!("SUPABASE_URL"),
  api_key: System.fetch_env!("SUPABASE_ANON_KEY"),
  jwt_secret: System.get_env("SUPABASE_JWT_SECRET")
```

## What's included

| Module | What it does |
| --- | --- |
| `AshSupabase.DataLayer` | An `Ash.DataLayer` over the Data API. Filters, sorts, pagination, counts, upserts and bulk writes are pushed down into one HTTP request. |
| `AshSupabase.Auth` | The GoTrue API: sign up, sign in, OAuth, magic links, OTP, password recovery, and the service-role admin endpoints. |
| `AshSupabase.Auth.JWT` | Local access-token verification — legacy HS256 **and** the current asymmetric ES256/RS256 keys, with JWKS caching and rotation. |
| `AshSupabase.Plug` | Reads the bearer token off a request, verifies it, and assigns the claims and current user. |
| `AshSupabase.Storage` | Buckets and objects: upload, download, list, move, copy, signed URLs, signed upload URLs, public URLs. |
| `AshSupabase.Realtime` | `postgres_changes` over Phoenix Channels, with the protocol and the state machine as pure, fully-tested code. |
| `AshSupabase.Rls` | Makes `auth.uid()` and `auth.jwt()` work when you use `AshPostgres` against Supabase's Postgres directly. |
| `AshSupabase.PostgREST` | The Data API client on its own, if you want it without Ash. |

## Two ways to reach Supabase

Supabase exposes the same database twice, and this library supports both.

**Over HTTPS, through the Data API** — use `AshSupabase.DataLayer`. Every
request carries the caller's JWT, so Row Level Security is enforced by Postgres
itself and you cannot accidentally read another tenant's rows. This is the right
choice when your app has no direct database connection, or when you want RLS to
be the last line of defence.

**Over a Postgres connection, through `AshPostgres`** — you get the whole of
Ash: joins, aggregates, transactions, atomic updates. But your connection role
bypasses RLS, so policies that call `auth.uid()` see nothing. `AshSupabase.Rls`
fixes that by setting the request's JWT claims and role inside each transaction,
exactly as PostgREST does.

You can use both in one application, resource by resource. See the
[data layer guide](documentation/topics/data-layer.md) for the trade-offs.

## Documentation

* [Getting started](documentation/tutorials/getting-started.md)
* [The data layer](documentation/topics/data-layer.md) — what is pushed down, and what is not
* [Authentication](documentation/topics/authentication.md)
* [Row Level Security](documentation/topics/rls.md)
* [Storage](documentation/topics/storage.md)
* [Realtime](documentation/topics/realtime.md)
* [Testing](documentation/topics/testing.md)

Full API reference at [hexdocs.pm/ash_supabase](https://hexdocs.pm/ash_supabase).

## Status

`0.1.0`. The data layer, PostgREST client, auth, JWT verification and storage
are covered by tests that assert the exact wire format — query strings, headers
and bodies — against the documented API. Realtime's protocol and state machine
are fully tested; its websocket transport needs a live server to exercise.

The library talks to a hosted API that evolves. If you hit a case it gets wrong,
[open an issue](https://github.com/seanchatmangpt/ash_supabase/issues) with the
request and response — that is the fastest path to a fix.

## License

MIT. See [LICENSE](LICENSE).
