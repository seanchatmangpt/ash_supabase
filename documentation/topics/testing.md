# Testing

Every module in `ash_supabase` sends its requests through `AshSupabase.Client`,
which is built on [`Req`](https://hexdocs.pm/req). That gives you one seam to
stub, and no test in this library — or in yours — needs a network.

## Point the client at a stub

```elixir
# config/test.exs
config :my_app, MyApp.Supabase,
  url: "http://localhost",
  api_key: "test-anon-key",
  jwt_secret: "a-test-secret-long-enough-for-hs256",
  req_options: [plug: {Req.Test, MyApp.Supabase}]
```

`Req.Test` stubs are owned by the process that sets them, so tests stay `async:
true`.

## Assert on the request, not just the result

The interesting bugs in an API client are in the *encoding*: a filter that
becomes the wrong query string still returns rows, just the wrong ones. So
assert on what actually went over the wire.

```elixir
defmodule MyApp.BlogTest do
  use ExUnit.Case, async: true

  require Ash.Query

  test "published posts are filtered server-side" do
    Req.Test.stub(MyApp.Supabase, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/rest/v1/posts"
      assert conn.query_string =~ "status=eq.published"

      Req.Test.json(conn, [%{"id" => "1", "title" => "Hello", "status" => "published"}])
    end)

    assert [%{title: "Hello"}] =
             MyApp.Blog.Post
             |> Ash.Query.filter(status == :published)
             |> Ash.read!()
  end
end
```

## Capture the request for later assertions

Asserting inside the stub means a failure surfaces as a confusing HTTP error.
Sending the conn back to the test process keeps failures readable:

```elixir
defp capture_request(responder) do
  parent = self()
  ref = make_ref()

  Req.Test.stub(MyApp.Supabase, fn conn ->
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send(parent, {ref, conn, body})
    responder.(conn)
  end)

  fn ->
    receive do
      {^ref, conn, body} -> {conn, body}
    after
      1_000 -> flunk("no request was made")
    end
  end
end
```

```elixir
test "creates send the column name, not the attribute name" do
  capture = capture_request(&Req.Test.json(&1, %{"id" => "1"}))

  Ash.create!(MyApp.Blog.Post, %{published?: true})

  {_conn, body} = capture.()
  assert Jason.decode!(body) == %{"is_published" => true}
end
```

This library's own test suite uses exactly this helper — see
`test/support/supabase_case.ex`.

## Testing error handling

Supabase's error bodies differ per service, and `ash_supabase` parses each. Use
real shapes so your handling is tested against what actually arrives.

```elixir
# PostgREST
Req.Test.stub(MyApp.Supabase, fn conn ->
  conn
  |> Plug.Conn.put_resp_content_type("application/json")
  |> Plug.Conn.send_resp(409, Jason.encode!(%{
    "code" => "23505",
    "message" => "duplicate key value violates unique constraint \"posts_title_key\"",
    "details" => "Key (title)=(Hello) already exists.",
    "hint" => nil
  }))
end)

# GoTrue
|> Plug.Conn.send_resp(400, Jason.encode!(%{
  "error_code" => "invalid_credentials",
  "msg" => "Invalid login credentials"
}))

# Storage
|> Plug.Conn.send_resp(404, Jason.encode!(%{
  "statusCode" => "404",
  "error" => "not_found",
  "message" => "Object not found",
  "code" => "NoSuchKey"
}))
```

A connection failure is a different class of error, and worth its own test:

```elixir
Req.Test.stub(MyApp.Supabase, &Req.Test.transport_error(&1, :econnrefused))

assert {:error, %AshSupabase.Error.Transport{}} = Ash.read(MyApp.Blog.Post)
```

## Testing JWT verification

Sign real tokens rather than mocking the verifier — it is barely more code and
it tests the thing you care about.

```elixir
test "rejects an expired token" do
  claims = %{"sub" => Ecto.UUID.generate(), "role" => "authenticated",
             "exp" => System.system_time(:second) - 60}

  token = sign_hs256(claims, "a-test-secret-long-enough-for-hs256")

  assert {:error, _} = AshSupabase.Auth.JWT.verify(MyApp.Supabase, token)
end
```

## Testing against a real Supabase

Some things — Realtime's websocket transport, RLS policies, database functions —
are only meaningfully tested against a running instance. The
[Supabase CLI](https://supabase.com/docs/guides/local-development) gives you one
locally:

```bash
supabase start   # prints the local url, anon key and service role key
```

```elixir
# config/test.exs
if System.get_env("SUPABASE_INTEGRATION") do
  config :my_app, MyApp.Supabase,
    url: "http://127.0.0.1:54321",
    api_key: System.fetch_env!("SUPABASE_ANON_KEY")
end
```

Tag those tests so they stay out of the default run:

```elixir
# test/test_helper.exs
ExUnit.start(exclude: [:integration])
```

```elixir
@tag :integration
test "the RLS policy actually hides other users' drafts" do
  # ...
end
```

```bash
mix test --include integration
```
