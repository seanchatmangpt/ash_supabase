# The data layer

`AshSupabase.DataLayer` maps Ash onto the Supabase Data API — PostgREST — over
HTTPS. This guide covers what it pushes into the request, what it deliberately
refuses, and how to tell which situation you are in before you ship.

## The DSL

```elixir
supabase do
  table "posts"
  client MyApp.Supabase
  schema "public"
  count_strategy :exact
  allow_unfiltered_writes? false
  headers [{"x-request-source", "my_app"}]
end
```

| Option | Default | Meaning |
| --- | --- | --- |
| `table` | *required* | The table or view name as exposed through the Data API. |
| `client` | *required* | The `AshSupabase.Client` module identifying the project. |
| `schema` | client's schema | The Postgres schema. Must be an **exposed schema** in the project's API settings, or requests fail with `PGRST106`. |
| `count_strategy` | `:exact` | `:exact` runs a real `COUNT(*)`. `:planned` and `:estimated` read the planner instead — far cheaper on large tables, and approximate. |
| `allow_unfiltered_writes?` | `false` | Whether a bulk update or destroy with no filter may run. See [Destructive requests](#destructive-requests). |
| `headers` | `[]` | Extra headers on every request for this resource. |

## What is pushed down

Everything below becomes part of one HTTP request.

| Ash | PostgREST |
| --- | --- |
| `Ash.Query.filter/2` | Filter parameters — see [Filter support](#filter-support) |
| `Ash.Query.sort/2` | `order=col.asc.nullsfirst` |
| `Ash.Query.limit/2` / `offset/2` | `limit=` / `offset=` |
| `Ash.Query.select/2` | `select=` (the primary key is always included) |
| `Ash.count/2`, offset pagination | `Prefer: count=exact` + a `HEAD` request, read from `Content-Range` |
| `Ash.create/3` | `POST` with `Prefer: return=representation` |
| `upsert?: true` | `Prefer: resolution=merge-duplicates` + `on_conflict=` |
| `Ash.bulk_create/4` | one `POST` with a JSON array |
| `Ash.update/3` / `Ash.destroy/2` | `PATCH` / `DELETE` filtered by primary key |
| `Ash.bulk_update/4` / `bulk_destroy/4` | one `PATCH` / `DELETE` filtered by the query |
| Context multitenancy | `Accept-Profile` / `Content-Profile` |
| Attribute multitenancy | an ordinary filter, added by Ash |

## Filter support

These translate faithfully:

| Ash expression | PostgREST |
| --- | --- |
| `field == value` | `field=eq.value` |
| `field != value` | `field=neq.value` |
| `field > / >= / < / <=` | `gt` / `gte` / `lt` / `lte` |
| `field in [...]` | `field=in.(a,b,c)` |
| `is_nil(field)` | `field=is.null` |
| `not is_nil(field)` | `field=not.is.null` |
| `contains(field, "x")` | `field=like.%x%` (`ilike` for `:ci_string`) |
| `string_starts_with/2`, `string_ends_with/2` | anchored `like` |
| `field in ^list` on an array column | `cs.{...}` |
| `and`, `or`, `not` | implicit AND, `or=(...)`, `not.` prefixes |

Two details worth knowing, because getting either wrong changes which rows come
back rather than producing an error:

**Values are quoted when they need to be.** PostgREST treats `,` `.` `:` `*` `(`
and `)` as structure inside a filter value. `AshSupabase.PostgREST.Encoder`
quotes any value containing one, so `title == "Hello, world"` becomes
`title=eq."Hello, world"` and not two broken filters.

**Nested logical groups drop the `=`.** At the top level a group is
`or=(a.eq.1,b.eq.2)`; nested inside another group it is `and(...)` with no
equals sign. Emitting `and=(...)` there is a `PGRST100` parse error. Negation is
pushed to the leaves with De Morgan's laws so a negated group never nests.

**Wildcards in user input are escaped.** `contains(title, "100%")` searches for a
literal `100%`; the `%` does not become a wildcard.

### What is refused, and why

Anything with no faithful PostgREST equivalent returns
`AshSupabase.Error.Unsupported` rather than an approximation, and
`can?/2` reports the same set so Ash refuses the query up front:

* **Relationship filters** — `filter(author.name == "x")`. PostgREST's embedded
  filters shape the embedded array, not the parent rows, unless you opt into an
  inner join; silently applying one would return the wrong rows.
* **Column-to-column comparison** — `filter(views > likes)`. Filter values are
  literals.
* **Filters on calculations and aggregates** — they have no column.
* **`fragment/1`, `exists/2`, JSON path expressions** — not translated in 0.1.

The workaround for all of these is the same: put the logic in a database view or
function and point a resource at it, or use `AshPostgres` for that resource.

## Limitations

These are properties of the Data API, not gaps in the implementation.

**No transactions.** PostgREST runs each request in its own transaction and
offers no way to span several, so `can?(:transact)` is `false`. A multi-step
Ash action is therefore *not atomic* — if the third write fails, the first two
stand. When you need atomicity, write a Postgres function and call it with
`AshSupabase.PostgREST.rpc/4`.

**No joins.** Relationships still load, but as one extra request each. A `load`
across three relationships is four round trips.

**No aggregates beyond count.** `sum`, `avg`, `min` and `max` need PostgREST's
aggregate functions, which Supabase disables by default (`PGRST123`). Expose a
view that computes them.

**No atomic updates.** `Ash.Changeset.atomic_update/3` builds a Postgres
expression; the Data API takes literal values. Set `require_atomic? false` on
actions that would otherwise use one. This also means **increment-style updates
are read-modify-write and can lose a concurrent update** — use an RPC function
for counters.

**Row cap.** Supabase caps responses at 1000 rows by default. A `limit` above
that is silently truncated. Paginate, and drive pagination off the count rather
than off the number of rows you asked for.

**RLS denials look like empty results.** With the publishable key and no
matching policy, a read returns `[]` with a 200, not a 403. An empty result is
not proof the row does not exist.

## Destructive requests

PostgREST scopes `PATCH` and `DELETE` **entirely by the query string**. A
request with no filters rewrites or deletes every row in the table, and the
service-role key bypasses RLS, so nothing else will stop it.

`ash_supabase` refuses an unfiltered bulk write by default:

```
** (AshSupabase.Error.Unsupported) Refusing to delete every row in "posts".
```

If emptying the table is genuinely the intent, opt in:

```elixir
supabase do
  table "posts"
  client MyApp.Supabase
  allow_unfiltered_writes? true
end
```

Single-record `Ash.update/3` and `Ash.destroy/2` are always filtered by primary
key, so they are never affected.

## Choosing between this and AshPostgres

| | `AshSupabase.DataLayer` | `AshPostgres` |
| --- | --- | --- |
| Transport | HTTPS | Postgres connection |
| RLS | enforced by default | bypassed unless you use `AshSupabase.Rls` |
| Joins, aggregates, transactions | no | yes |
| Works without database access | yes | no |
| Requests per relationship load | one each | one query |

They coexist. A common shape is `AshPostgres` for resources your server owns,
and `AshSupabase.DataLayer` for resources where RLS should be the last line of
defence. See the [RLS guide](rls.md) for making policies work under
`AshPostgres`.

## Using the client without Ash

`AshSupabase.PostgREST` is a complete Data API client in its own right:

```elixir
alias AshSupabase.PostgREST
alias AshSupabase.PostgREST.Query

Query.new("posts")
|> Query.select([:id, :title])
|> Query.add_filters([{"status", "eq.published"}])
|> Query.limit(10)
|> then(&PostgREST.run(MyApp.Supabase, &1))
```
