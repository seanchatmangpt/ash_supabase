# Storage

`AshSupabase.Storage` covers the Supabase Storage API: buckets, objects, signed
URLs and signed uploads. Every call goes through `AshSupabase.Client`, so
`:token`, `:headers` and `:req_options` work the same as everywhere else.

## Buckets

```elixir
{:ok, buckets} = AshSupabase.Storage.list_buckets(MyApp.Supabase)

{:ok, "avatars"} =
  AshSupabase.Storage.create_bucket(MyApp.Supabase, "avatars",
    public: false,
    file_size_limit: "5MB",
    allowed_mime_types: ["image/png", "image/jpeg"]
  )
```

Also: `get_bucket/3`, `update_bucket/3`, `empty_bucket/3` (delete the contents)
and `delete_bucket/3` (delete the bucket, which must be empty first).

`list_buckets/2` takes `:limit`, `:offset`, `:sort_column`, `:sort_order` and
`:search`.

## Objects

```elixir
{:ok, key} =
  AshSupabase.Storage.upload(MyApp.Supabase, "avatars", "user-1/photo.png", binary,
    content_type: "image/png",
    cache_control: 3600,
    upsert: false
  )

{:ok, bytes} = AshSupabase.Storage.download(MyApp.Supabase, "avatars", "user-1/photo.png")
```

`upload/5` takes a binary or `{:file, path}` — the file is read for you, and an
unreadable path returns `{:error, %File.Error{}}` without making a request.

`update/5` is the same as upload with overwrite forced on (`PUT` rather than
`POST`). `upload/5` with `upsert: true` is equivalent.

Downloads are returned as **raw bytes**, never decoded — binary files survive
intact.

Listing, moving, copying and deleting:

```elixir
{:ok, objects} =
  AshSupabase.Storage.list(MyApp.Supabase, "avatars", prefix: "user-1/", limit: 100)

:ok = AshSupabase.Storage.move(MyApp.Supabase, "avatars", "old.png", "new.png")
:ok = AshSupabase.Storage.copy(MyApp.Supabase, "avatars", "a.png", "b.png")

{:ok, removed} = AshSupabase.Storage.remove(MyApp.Supabase, "avatars", ["a.png", "b.png"])
```

`list/3` returns folder entries too — a folder comes back with `id: nil` and
null timestamps, which is how you tell it from an object.

### Object keys and encoding

Keys go in the URL path, and `AshSupabase.Storage` percent-encodes them for you:
the key is split on `/` so folder separators survive, and each segment is
encoded so spaces, `?` and `#` cannot break out of the path.

```elixir
AshSupabase.Storage.encode_key("holiday photos/why? #1.png")
#=> "holiday%20photos/why%3F%20%231.png"
```

Keys inside JSON bodies — `move/5`, `copy/5`, `remove/4`, `list/3` — are sent
**unencoded**, because there they are data rather than URL. You do not need to
do anything about either case; it is worth knowing if you are comparing requests
against another client.

## Serving files

Three ways, with different security properties.

**Public buckets.** `public_url/4` is a pure function — no request, no
expiry, no authorization.

```elixir
AshSupabase.Storage.public_url(MyApp.Supabase, "avatars", "user-1/photo.png")
#=> "https://abcdefgh.supabase.co/storage/v1/object/public/avatars/user-1/photo.png"
```

**Signed URLs.** Time-limited access to a private object. Anyone holding the URL
can read it until it expires, so treat it as a bearer credential.

```elixir
{:ok, url} =
  AshSupabase.Storage.create_signed_url(MyApp.Supabase, "avatars", "user-1/photo.png", 3600)

{:ok, results} =
  AshSupabase.Storage.create_signed_urls(MyApp.Supabase, "avatars", ["a.png", "b.png"], 3600)
```

The API returns a *relative* path; `ash_supabase` returns the absolute URL, which
is what you actually want to hand a browser.

**Authenticated download.** `download/4` fetches the bytes through your server
with the caller's token, so Storage RLS policies apply.

## Direct browser uploads

To let a browser upload without giving it any credential, mint a signed upload
URL on the server and hand that over:

```elixir
{:ok, signed} =
  AshSupabase.Storage.create_signed_upload_url(MyApp.Supabase, "avatars", "user-1/photo.png")

signed.url    # absolute, carries a one-time token
signed.token
```

The holder uploads with a `PUT` to that URL and no `Authorization` header at
all. `upload_to_signed_url/4` does it from Elixir, which is mainly useful in
tests.

## Storage errors look different

Storage does **not** use PostgREST's error shape. It returns:

```json
{"statusCode": "404", "error": "not_found", "message": "Object not found", "code": "NoSuchKey"}
```

Note `statusCode` is a *string*. `AshSupabase.Error` parses this into the same
`AshSupabase.Error.Request` you get everywhere else, so `error.code` gives you
`"NoSuchKey"` and `error.status` the integer status.

```elixir
case AshSupabase.Storage.download(MyApp.Supabase, "avatars", key) do
  {:ok, bytes} -> bytes
  {:error, %AshSupabase.Error.Request{code: "NoSuchKey"}} -> :not_found
  {:error, error} -> raise error
end
```

## Storage and RLS

Storage objects live in the `storage.objects` table, and RLS applies to them the
same way it applies to your own tables. Pass a user's token so their policies
are the ones evaluated:

```elixir
AshSupabase.Storage.upload(MyApp.Supabase, "avatars", key, bytes,
  token: conn.assigns.supabase_token
)
```

```sql
create policy "users manage their own folder"
  on storage.objects for all
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
```
