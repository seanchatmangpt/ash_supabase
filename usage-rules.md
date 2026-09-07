# Using ash_supabase

Rules for working with `ash_supabase`. These are the things that are easy to get
wrong and expensive to discover late.

## Client setup

A client module names one Supabase project.

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

Use the **publishable/anon** key as the default. The **secret/service_role** key
has Postgres `BYPASSRLS` and skips every policy — pass it per call for admin
operations, never as the default client.

## Resources

```elixir
defmodule MyApp.Blog.Post do
  use Ash.Resource, domain: MyApp.Blog, data_layer: AshSupabase.DataLayer

  supabase do
    table "posts"       # required
    client MyApp.Supabase  # required
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
  end
end
```

- `table` and `client` are both required; a missing one is a compile-time error.
- A `schema` other than the default must be listed as an **exposed schema** in
  the project's Data API settings, or you get `PGRST106`.
- Give the resource a primary key. Without one, `update` and `destroy` cannot
  address a row, because PostgREST identifies rows by filter, not by path.

## Running as a user

This is the single most important call in the library. Without it, every request
runs as `anon`.

```elixir
Post
|> Ash.Query.filter(status == :published)
|> AshSupabase.DataLayer.with_token(session.access_token)
|> Ash.read!()
```

`with_token/2` accepts a query, a changeset, an action input, or a resource
module.

In Phoenix, `AshSupabase.Plug` puts the verified token in
`conn.assigns.supabase_token`.

## What the data layer cannot do

Do not write code that assumes these work — `can?/2` reports them honestly, so
Ash raises rather than silently doing the wrong thing, but design around them:

- **No transactions.** Multi-step actions are not atomic. Use a Postgres
  function via `AshSupabase.PostgREST.rpc/4` when you need atomicity.
- **No relationship filters.** `filter(author.name == "x")` is unsupported. Use
  a view, or `AshPostgres`.
- **No aggregates except `count`.**
- **No atomic updates.** Set `require_atomic? false` on actions that would use
  one. Counters are read-modify-write and can lose concurrent updates — use an
  RPC function.
- **Relationships load one request each.** A `load` of three relationships is
  four round trips.
- **1000-row cap** by default. Paginate; drive pagination off the count.

## Reading results

- An empty list can mean "RLS denied it", not "there is nothing there". Reads
  under `anon` with no matching policy return `[]` with a 200, never a 403.
- A counted, paginated read returns HTTP 206. That is success.

## Destructive writes

`Ash.bulk_update/4` and `Ash.bulk_destroy/4` with no filter would rewrite or
delete **every row in the table**, because PostgREST scopes writes entirely by
the query string. `ash_supabase` refuses this by default. If you mean it:

```elixir
supabase do
  allow_unfiltered_writes? true
end
```

Single-record `Ash.update/3` and `Ash.destroy/2` are always filtered by primary
key and are never affected.

## Authentication

```elixir
{:ok, session} = AshSupabase.Auth.sign_in_with_password(MyApp.Supabase, %{email: e, password: p})
{:ok, claims} = AshSupabase.Auth.JWT.verify(MyApp.Supabase, session.access_token)
```

- `verify/3` handles both the legacy HS256 secret and current asymmetric
  (ES256/RS256) keys automatically. Configure `:jwt_secret` only if the project
  still uses HS256 — an HS256-only project publishes an empty JWKS.
- `peek_claims/1` does **not** verify. Never authorize on it.
- Authorize on `app_metadata`, never `user_metadata` — users can edit the latter
  through `update_user/3`.
- Refresh tokens are single-use. Store the new one from every refresh.
- `Session.expired?/2` fails closed.

## RLS with AshPostgres

If you reach Postgres directly rather than through the Data API, RLS policies
that call `auth.uid()` see nothing until you do this:

```elixir
defmodule MyApp.Repo do
  use AshPostgres.Repo, otp_app: :my_app
  use AshSupabase.Rls.Repo
end
```

```elixir
plug AshSupabase.Plug, client: MyApp.Supabase, put_claims: true
```

Then note: **Ash read actions are not transactional by default**, so the hook
does not fire for them. Set `transaction? true` on read actions that rely on
RLS. In background jobs, wrap work in `AshSupabase.Rls.with_claims/2`.

## Storage

- `download/4` returns raw bytes, undecoded.
- `create_signed_url/5` returns an absolute URL; treat it as a bearer credential.
- `public_url/4` is a pure function and only works for public buckets.
- Storage errors use their own shape (`code` is like `"NoSuchKey"`), parsed into
  the same `AshSupabase.Error.Request`.

## Realtime

- Add the table to the publication first: `alter publication supabase_realtime
  add table posts;`
- For a full `old_record` on updates and deletes: `alter table posts replica
  identity full;`
- Realtime filters are far more limited than PostgREST's: one
  `column=op.value`, no `and`/`or`. Use several subscriptions.
- It is not a queue. Missed events while disconnected are gone.
- Needs the optional `{:mint_web_socket, "~> 1.0"}` dependency.

## Testing

Never hit the network. Point the client at a `Req.Test` stub:

```elixir
config :my_app, MyApp.Supabase,
  url: "http://localhost",
  api_key: "test",
  req_options: [plug: {Req.Test, MyApp.Supabase}]
```

Assert on `conn.method`, `conn.request_path`, `conn.query_string` and the parsed
body — the interesting bugs are in the encoding, and a wrongly-encoded filter
returns rows, just the wrong ones.

## Errors

All errors are `Splode.Error`s that compose with `Ash.Error`:

- `AshSupabase.Error.Request` — the API rejected it. `:status`, `:code`
  (a SQLSTATE like `"23505"` or a PostgREST code like `"PGRST116"`),
  `:supabase_message`, `:details`, `:hint`.
- `AshSupabase.Error.Transport` — the request never completed.
- `AshSupabase.Error.Configuration` — misconfiguration.
- `AshSupabase.Error.Unsupported` — no faithful equivalent in the Data API.
