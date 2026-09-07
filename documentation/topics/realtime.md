# Realtime

`AshSupabase.Realtime` subscribes to Postgres change events over Supabase
Realtime, which is the Phoenix Channels protocol over a WebSocket.

```elixir
# Under your application supervisor
{AshSupabase.Realtime, client: MyApp.Supabase, name: MyApp.Realtime}
```

```elixir
:ok =
  AshSupabase.Realtime.subscribe(MyApp.Realtime, "posts",
    postgres_changes: [
      [event: "*", schema: "public", table: "posts"]
    ]
  )
```

The calling process then receives:

```elixir
def handle_info({:realtime_change, %AshSupabase.Realtime.Change{} = change}, state) do
  change.type              # :insert | :update | :delete
  change.schema            # "public"
  change.table             # "posts"
  change.record            # the new row, as a map (nil for a delete)
  change.old_record        # the previous row, when REPLICA IDENTITY FULL is set
  change.commit_timestamp  # a DateTime
  {:noreply, state}
end

def handle_info({:realtime_error, reason}, state), do: {:noreply, state}
```

Subscribers are monitored: when the last one for a topic goes away, the socket
is closed and cleaned up.

## Filtering

Filters are applied server-side, so you only receive matching events:

```elixir
AshSupabase.Realtime.subscribe(MyApp.Realtime, "posts:published",
  postgres_changes: [
    [event: "UPDATE", schema: "public", table: "posts", filter: "status=eq.published"]
  ]
)
```

The filter grammar is PostgREST's, but Realtime supports far less of it — a
single `column=op.value` with `eq`, `neq`, `lt`, `lte`, `gt`, `gte` or `in`. No
`or`, no `and`, no multiple filters per subscription. Use several subscriptions
instead.

## Enable it on the table first

Realtime reads from a Postgres publication, and a table is not in it by default:

```sql
alter publication supabase_realtime add table posts;

-- Without this, `old_record` on an UPDATE or DELETE contains only the primary
-- key. With it, the whole previous row — at some write cost.
alter table posts replica identity full;
```

RLS applies to Realtime too: subscribe with a user's token and they receive only
the changes their policies let them see.

```elixir
AshSupabase.Realtime.subscribe(MyApp.Realtime, "posts",
  access_token: conn.assigns.supabase_token,
  postgres_changes: [[event: "*", schema: "public", table: "posts"]]
)
```

Tokens expire. Push a fresh one and the connection is kept:

```elixir
:ok = AshSupabase.Realtime.set_auth(MyApp.Realtime, new_access_token)
```

## How this is built, and what that means for trust

Realtime is the one part of this library that cannot be fully tested without a
live server, so it is split so that almost all of it can be:

* **`AshSupabase.Realtime.Message`** — pure encoding and decoding of the
  Channels v1.0.0 envelope and of `postgres_changes` payloads. Fully unit
  tested against captured message shapes.
* **`AshSupabase.Realtime.Channel`** — a pure state machine. `handle_message/3`
  takes a message and returns `{new_state, effects}`; time is passed in rather
  than read. Join, binding-id reconciliation, heartbeats, rejoin backoff and
  token refresh are all tested here, with no network.
* **`AshSupabase.Realtime.Socket`** — a thin `Mint.WebSocket` GenServer that
  moves bytes and delegates every decision to the two modules above. This is the
  part that needs a live server.

So the protocol logic is covered; the transport is deliberately small enough to
read in one sitting.

### The optional dependency

The socket needs `mint_web_socket`, which is optional:

```elixir
{:mint_web_socket, "~> 1.0"}
```

Without it the rest of the library still compiles and works; starting a socket
raises an error naming that exact line.

## Type coercion

Realtime sends every column value as a string, with the column types alongside.
`AshSupabase.Realtime.Message` converts the types it can do faithfully —
integers, floats and numerics, booleans, `json`/`jsonb`, timestamps, and array
literals — and passes everything else through unchanged rather than guessing.

Guessing would be worse than not converting: a value silently coerced to the
wrong type is a bug you find in production. If you need a type that is not
covered, `convert: false` gives you the raw wire values.

## Running against a local server

```bash
supabase start
```

```elixir
{:ok, pid} =
  AshSupabase.Realtime.start_link(
    client: [url: "http://127.0.0.1:54321", api_key: System.fetch_env!("SUPABASE_ANON_KEY")],
    name: MyRealtime
  )

AshSupabase.Realtime.subscribe(MyRealtime, "posts",
  postgres_changes: [[event: "*", schema: "public", table: "posts"]]
)

flush()
```

Then insert a row in the Supabase Studio and watch the message arrive.

## Realtime is not a queue

Events are delivered at most once, only while you are connected. A subscriber
that reconnects does not receive what it missed. If you need durability, write to
an outbox table and drive that with `AshOban` or a similar worker; use Realtime
for live UI updates, where a missed event self-corrects on the next one.
