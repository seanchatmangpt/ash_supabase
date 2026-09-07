# Row Level Security

Row Level Security moves authorization into the database, so a bug in your
application cannot leak another user's rows. Whether it protects you depends
entirely on *which role your connection runs as* — and that differs between the
two ways of reaching Supabase.

## Through the Data API: it just works

`AshSupabase.DataLayer` sends every request over HTTPS with a JWT. PostgREST
reads the `role` claim and switches the Postgres session to it, so policies are
evaluated against the caller.

| What you send | Effective role | RLS |
| --- | --- | --- |
| publishable (anon) key only | `anon` | enforced |
| a user's access token | `authenticated`, with their claims | enforced |
| secret (service role) key | `service_role` | **bypassed entirely** |

```elixir
MyApp.Blog.Post
|> AshSupabase.DataLayer.with_token(conn.assigns.supabase_token)
|> Ash.read!()
```

`auth.uid()` now returns that user's id and `auth.jwt()` the whole token.

Two things to internalize:

**`Authorization` wins over `apikey`.** The `apikey` header identifies your
application to Supabase's gateway; `Authorization` decides the Postgres role.
Sending the secret key in `Authorization` runs as `service_role` no matter what
`apikey` says.

**A denial looks like an empty list.** With no matching policy a read returns
`[]` with a 200 — not a 403. Never treat an empty result as proof a row does not
exist.

## Through AshPostgres: it does not, until you make it

`AshPostgres` connects directly to Postgres as your configured role, which
generally has `BYPASSRLS` or simply is not `authenticated`. Policies that call
`auth.uid()` see `NULL`, so a policy like `using (auth.uid() = author_id)`
silently matches nothing — or, with `BYPASSRLS`, is skipped altogether.

`AshSupabase.Rls` closes that gap by doing what PostgREST does: setting the
request's claims and role on the connection, inside the transaction.

### Set it up

```elixir
defmodule MyApp.Repo do
  use AshPostgres.Repo, otp_app: :my_app
  use AshSupabase.Rls.Repo
end
```

```elixir
pipeline :api do
  plug AshSupabase.Plug, client: MyApp.Supabase, put_claims: true
end
```

The plug stores the verified claims in the process; the repo's
`on_transaction_begin/1` hook emits, inside each transaction:

```sql
select set_config('request.jwt.claims', $1, true);
set local role "authenticated";
```

`is_local = true` scopes both to the transaction, so nothing leaks onto the next
checkout of a pooled connection. With no claims present the role is `anon` and
the claims setting is cleared — explicitly, every time, so a previous action's
setting can never carry over.

### Three things that will bite you

**Reads are not transactional by default.** Ash read actions run with
`transaction? false`, so `on_transaction_begin/1` never fires for them and the
claims are never set. Mark actions that rely on RLS:

```elixir
read :list do
  transaction? true
end
```

**`:create` transaction reasons carry no actor.** Ash's `transaction_reason`
includes `:actor` for `:read`, `:update` and `:destroy`, but not for `:create`.
This is why claims live in the process store rather than being derived from the
reason. The `:claims` option gives you a fallback for cases the store cannot
cover:

```elixir
use AshSupabase.Rls.Repo,
  claims: fn
    %{metadata: %{actor: %{id: id}}} -> %{"sub" => id, "role" => "authenticated"}
    _ -> nil
  end
```

**Background jobs have no request.** A worker process has an empty claim store
and will run as `anon`. Set claims explicitly:

```elixir
AshSupabase.Rls.with_claims(%{"sub" => user_id, "role" => "authenticated"}, fn ->
  Ash.create!(MyApp.Blog.Post, params)
end)
```

`with_claims/2` restores the previous value afterwards, including when the
function raises. Claims are also visible to processes started by the current one
— `AshSupabase.Rls` walks `$callers` — so Ash's concurrent loads inherit the
caller's identity rather than silently dropping to `anon`.

### Injection safety

Postgres will not accept a role name as a bind parameter, so the role has to be
interpolated. `AshSupabase.Rls` validates it against `[A-Za-z_][A-Za-z0-9_$]*`
(max 63 bytes) and raises `ArgumentError` otherwise. That check matters because
the role can come from a `role` claim in a token — attacker-influenced input
reaching a string interpolation into SQL. Claims themselves are always passed as
a bind parameter.

`set_config_statements/2` is a pure function returning `[{sql, params}]`, so you
can assert on exactly what would run:

```elixir
iex> AshSupabase.Rls.set_config_statements(%{"sub" => "u1", "role" => "authenticated"})
[
  {"select set_config('request.jwt.claims', $1, true)", ["{\"sub\":\"u1\",\"role\":\"authenticated\"}"]},
  {"set local role \"authenticated\"", []}
]
```

## Writing policies

Ash policies and RLS policies solve different halves of the problem, and both
are worth having:

* **RLS** is the backstop. It holds even if your application has a bug, and it
  is the only thing protecting you when a client talks to the Data API directly.
* **Ash policies** produce good errors, are testable in Elixir, and can express
  things SQL cannot.

Two patterns worth knowing:

```sql
-- Read your own rows plus anything published.
create policy "read own or published" on posts for select
  using (auth.uid() = author_id or status = 'published');

-- `with check` governs the row *after* the write; without it, a user can
-- update their own row to belong to someone else.
create policy "write own" on posts for update
  using (auth.uid() = author_id)
  with check (auth.uid() = author_id);
```

Authorize on `app_metadata`, never `user_metadata` — the latter is editable by
the user through `update_user/3`, so a role stored there is a role they can
grant themselves.

```sql
create policy "admins see everything" on posts for select
  using ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');
```

## Testing policies

Policies are SQL, so they need a real database. Run one locally with the
Supabase CLI and tag the tests — see the [testing guide](testing.md).
