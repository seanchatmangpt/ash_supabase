# Getting started

This guide takes you from an empty Phoenix or Elixir project to reading and
writing Supabase data through Ash, with Row Level Security enforced against the
signed-in user.

## 1. Add the dependency

```elixir
# mix.exs
def deps do
  [
    {:ash, "~> 3.33"},
    {:ash_supabase, "~> 0.1"}
  ]
end
```

```bash
mix deps.get
mix ash_supabase.install
```

The installer creates a client module, adds a `config/runtime.exs` block, and
adds `:ash_supabase` to your `.formatter.exs`. It is idempotent, so running it
again is safe.

## 2. Configure the client

A *client module* names one Supabase project.

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

Find these in your project dashboard under **Project Settings → API**.

> #### Which key? {: .warning}
>
> Use the **publishable** (anon) key. It selects the `anon` Postgres role, so
> Row Level Security is enforced. The **secret** (service role) key has the
> Postgres `BYPASSRLS` attribute and skips every policy — it belongs only in
> trusted server-side code, and never in anything a browser can reach.
>
> Newer projects issue keys prefixed `sb_publishable_` and `sb_secret_`; older
> ones issue JWTs. Both work — treat the key as an opaque string.

## 3. Create the table

In the Supabase SQL editor:

```sql
create table posts (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text,
  status text not null default 'draft',
  author_id uuid references auth.users (id) default auth.uid(),
  inserted_at timestamptz not null default now()
);

alter table posts enable row level security;

create policy "anyone can read published posts"
  on posts for select
  using (status = 'published');

create policy "authors manage their own posts"
  on posts for all
  using (auth.uid() = author_id)
  with check (auth.uid() = author_id);
```

That last policy is the point of the whole exercise: the database, not your
application code, decides who may see and change a row.

## 4. Define the resource

```elixir
defmodule MyApp.Blog do
  use Ash.Domain

  resources do
    resource MyApp.Blog.Post
  end
end

defmodule MyApp.Blog.Post do
  use Ash.Resource, domain: MyApp.Blog, data_layer: AshSupabase.DataLayer

  supabase do
    table "posts"
    client MyApp.Supabase
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :body, :string, public?: true
    attribute :status, :atom, constraints: [one_of: [:draft, :published]], public?: true
    attribute :author_id, :uuid, public?: true
    create_timestamp :inserted_at
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
```

`mix ash_supabase.gen.resource` generates this skeleton for you.

## 5. Read and write

```elixir
iex> MyApp.Blog.Post |> Ash.Query.filter(status == :published) |> Ash.read!()
[%MyApp.Blog.Post{title: "Hello", ...}]

iex> Ash.create!(MyApp.Blog.Post, %{title: "Draft one"})
%MyApp.Blog.Post{...}
```

Both go out as a single HTTP request against the Data API.

## 6. Act as a signed-in user

So far every request has run as `anon`, so only the "published" policy applied.
To let a user see their own drafts, sign them in and pass their token.

```elixir
{:ok, session} =
  AshSupabase.Auth.sign_in_with_password(MyApp.Supabase, %{
    email: "user@example.com",
    password: "correct horse battery staple"
  })

MyApp.Blog.Post
|> AshSupabase.DataLayer.with_token(session.access_token)
|> Ash.read!()
```

Now `auth.uid()` returns that user's id, the second policy applies, and they see
their drafts. Nothing in your Elixir code filtered by author — Postgres did.

## 7. Wire it into Phoenix

`AshSupabase.Plug` verifies the incoming bearer token and assigns the result, so
controllers do not have to.

```elixir
# lib/my_app_web/router.ex
pipeline :api do
  plug :accepts, ["json"]
  plug AshSupabase.Plug, client: MyApp.Supabase
end
```

```elixir
def index(conn, _params) do
  posts =
    MyApp.Blog.Post
    |> AshSupabase.DataLayer.with_token(conn.assigns.supabase_token)
    |> Ash.read!(actor: conn.assigns.current_user)

  json(conn, posts)
end
```

Verification happens locally against the project's signing keys — no round trip
to Supabase per request. See the [authentication guide](authentication.md).

## Where to go next

* [The data layer](../topics/data-layer.md) — what gets pushed into the request,
  and what PostgREST cannot do.
* [Row Level Security](../topics/rls.md) — including how to keep policies working
  if you switch to `AshPostgres`.
* [Testing](../topics/testing.md) — how to test all of this without a network.
