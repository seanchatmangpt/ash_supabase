defmodule AshSupabase.Storage do
  @moduledoc """
  A complete client for the Supabase Storage API (`/storage/v1`).

  Every call goes through `AshSupabase.Client`, so it picks up the project URL,
  the `apikey` header and the bearer token from your client module, and accepts
  `:token` to act as a signed-in user (Storage RLS policies are evaluated
  against that JWT).

      defmodule MyApp.Supabase do
        use AshSupabase.Client, otp_app: :my_app
      end

      {:ok, _} = AshSupabase.Storage.create_bucket(MyApp.Supabase, "avatars", public: true)

      {:ok, %{key: "avatars/ada/cat.png"}} =
        AshSupabase.Storage.upload(MyApp.Supabase, "avatars", "ada/cat.png", File.read!("cat.png"),
          content_type: "image/png",
          upsert: true
        )

      {:ok, url} =
        AshSupabase.Storage.create_signed_url(MyApp.Supabase, "avatars", "ada/cat.png", 3600)

  ## Object keys and percent-encoding

  An object key is a *path*: `"ada/cat.png"` puts `cat.png` inside the `ada`
  folder, and listing the bucket with `prefix: "ada"` finds it. So the `/`
  characters in a key are structural and must reach the server as separators,
  while everything else in a segment must not be able to change the meaning of
  the URL.

  This module therefore splits a key on `/` and percent-encodes each segment
  individually, escaping every character outside the unreserved set
  (`A-Z a-z 0-9 - _ . ~`). A key of `"a b/c?d.png"` is sent as
  `a%20b/c%3Fd.png`: the slash survives, the space and the question mark do not.
  See `encode_key/1`.

  Keys sent in a JSON *body* (move, copy, remove, list) are **not** encoded —
  they are values, not URL syntax, and encoding them there would create objects
  with literal `%20` in their names.

  ## Signed URLs

  `POST /object/sign/...` answers with a *relative* path
  (`"/object/sign/avatars/cat.png?token=eyJ..."`). `create_signed_url/5`,
  `create_signed_urls/5` and `create_signed_upload_url/4` prefix it with
  `<project url>/storage/v1` and hand back an absolute URL you can give to a
  browser directly.

  ## Uploads

  `upload/5` and `update/5` send the bytes as a raw request body with the
  object's own `content-type`, which is the form storage-js uses for anything
  that is not a browser `File`. The body may be a binary or a `{:file, path}`
  tuple; a file is read into memory, so reach for the resumable (TUS) endpoint
  for very large files.
  """

  alias AshSupabase.Client
  alias AshSupabase.Config
  alias AshSupabase.Error
  alias AshSupabase.Storage.Bucket
  alias AshSupabase.Storage.Object

  @typedoc "The result of a Storage call."
  @type result(value) :: {:ok, value} | {:error, Exception.t()}

  @typedoc """
  Upload payload: raw bytes, or a file on disk to read them from.
  """
  @type body :: binary() | {:file, Path.t()}

  @typedoc """
  What `create_signed_upload_url/4` returns, and what `upload_to_signed_url/4`
  accepts: the bucket, the key, the one-shot upload token and the absolute URL
  the token belongs to.
  """
  @type signed_upload :: %{
          bucket: String.t(),
          path: String.t(),
          token: String.t(),
          signed_url: String.t()
        }

  @prefix "/storage/v1"
  @default_content_type "application/octet-stream"

  # ----------------------------------------------------------------------------
  # Buckets
  # ----------------------------------------------------------------------------

  @doc """
  Lists the buckets the current credentials can see.

  ## Options

    * `:limit` / `:offset` - pagination.
    * `:sort_column` - one of `:id`, `:name`, `:created_at`, `:updated_at`.
    * `:sort_order` - `:asc` or `:desc`.
    * `:search` - substring match on the bucket name.
    * `:token` - act as this user's JWT.
  """
  @spec list_buckets(Client.t(), keyword()) :: result([Bucket.t()])
  def list_buckets(client, opts \\ []) do
    path = @prefix <> "/bucket"

    params =
      []
      |> put_param(:limit, opts[:limit])
      |> put_param(:offset, opts[:offset])
      |> put_param(:sortColumn, opts[:sort_column])
      |> put_param(:sortOrder, opts[:sort_order])
      |> put_param(:search, opts[:search])

    with {:ok, %{body: body}} <-
           Client.request(client, :get, path, [params: params] ++ forwarded(opts)),
         {:ok, rows} <- expect_list(body, :get, path) do
      {:ok, Bucket.from_json_list(rows)}
    end
  end

  @doc """
  Fetches one bucket by id.
  """
  @spec get_bucket(Client.t(), String.t(), keyword()) :: result(Bucket.t())
  def get_bucket(client, bucket, opts \\ []) do
    path = bucket_path(bucket)

    with {:ok, %{body: body}} <- Client.request(client, :get, path, forwarded(opts)),
         {:ok, row} <- expect_map(body, :get, path) do
      {:ok, Bucket.from_json(row)}
    end
  end

  @doc """
  Creates a bucket and returns its name.

  ## Options

    * `:id` - the bucket id. Defaults to `name` server-side.
    * `:public` - make objects readable without a token. Defaults to `false`.
    * `:type` - `"STANDARD"` (default) or `"ANALYTICS"`.
    * `:file_size_limit` - bytes, or a string such as `"5MB"`, or `nil`.
    * `:allowed_mime_types` - a list of permitted MIME types.
    * `:token` - act as this user's JWT.
  """
  @spec create_bucket(Client.t(), String.t(), keyword()) :: result(String.t())
  def create_bucket(client, name, opts \\ []) do
    path = @prefix <> "/bucket"

    json =
      %{"name" => name}
      |> maybe_put("id", opts[:id])
      |> maybe_put("public", opts[:public])
      |> maybe_put("type", opts[:type])
      |> maybe_put("file_size_limit", opts[:file_size_limit])
      |> maybe_put("allowed_mime_types", opts[:allowed_mime_types])

    with {:ok, %{body: body}} <-
           Client.request(client, :post, path, [json: json] ++ forwarded(opts)) do
      fetch_key(body, "name", :post, path)
    end
  end

  @doc """
  Updates a bucket's settings.

  At least one of `:public`, `:file_size_limit` or `:allowed_mime_types` must be
  given — the API rejects an empty update, so this refuses it before the request
  is made.
  """
  @spec update_bucket(Client.t(), String.t(), keyword()) :: :ok | {:error, Exception.t()}
  def update_bucket(client, bucket, opts \\ []) do
    json =
      %{}
      |> maybe_put("public", opts[:public])
      |> maybe_put("file_size_limit", opts[:file_size_limit])
      |> maybe_put("allowed_mime_types", opts[:allowed_mime_types])

    if json == %{} do
      {:error,
       Error.Configuration.exception(
         message: """
         update_bucket/3 needs at least one of :public, :file_size_limit or \
         :allowed_mime_types.\
         """
       )}
    else
      with {:ok, _response} <-
             Client.request(client, :put, bucket_path(bucket), [json: json] ++ forwarded(opts)) do
        :ok
      end
    end
  end

  @doc """
  Deletes a bucket. The bucket must already be empty; see `empty_bucket/3`.
  """
  @spec delete_bucket(Client.t(), String.t(), keyword()) :: :ok | {:error, Exception.t()}
  def delete_bucket(client, bucket, opts \\ []) do
    with {:ok, _response} <-
           Client.request(client, :delete, bucket_path(bucket), forwarded(opts)) do
      :ok
    end
  end

  @doc """
  Queues deletion of every object in a bucket.

  Requires a service-role key. The server answers immediately and does the work
  asynchronously — "completion may take up to an hour" — so a following
  `delete_bucket/3` can still fail with a non-empty bucket.
  """
  @spec empty_bucket(Client.t(), String.t(), keyword()) :: :ok | {:error, Exception.t()}
  def empty_bucket(client, bucket, opts \\ []) do
    path = bucket_path(bucket) <> "/empty"

    with {:ok, _response} <- Client.request(client, :post, path, [json: %{}] ++ forwarded(opts)) do
      :ok
    end
  end

  # ----------------------------------------------------------------------------
  # Objects
  # ----------------------------------------------------------------------------

  @doc """
  Uploads an object with `POST`, which fails if the key already exists unless
  `upsert: true` is given.

  `body` is either a binary or `{:file, path}`.

  ## Options

    * `:content_type` - the object's MIME type. Defaults to
      `"application/octet-stream"`; Storage stores this verbatim and serves it
      back on download, so set it for anything a browser should render.
    * `:cache_control` - an integer number of seconds (sent as
      `cache-control: max-age=N`) or a literal header value.
    * `:upsert` - `true` sends `x-upsert: true`, allowing an overwrite.
    * `:metadata` - a map of user metadata, sent base64-encoded in `x-metadata`.
    * `:token` - act as this user's JWT.

  Returns `{:ok, %{id: id, key: key, bucket: bucket, path: path}}`, where `key`
  is the API's `Key` and therefore includes the bucket prefix.
  """
  @spec upload(Client.t(), String.t(), String.t(), body(), keyword()) ::
          result(%{id: String.t() | nil, key: String.t(), bucket: String.t(), path: String.t()})
  def upload(client, bucket, path, body, opts \\ []) do
    do_upload(client, :post, object_path(bucket, path), bucket, path, body, opts)
  end

  @doc """
  Replaces an existing object with `PUT`.

  Identical to `upload/5` except that the server always upserts, so this is the
  call to use when the key is expected to exist.
  """
  @spec update(Client.t(), String.t(), String.t(), body(), keyword()) ::
          result(%{id: String.t() | nil, key: String.t(), bucket: String.t(), path: String.t()})
  def update(client, bucket, path, body, opts \\ []) do
    do_upload(client, :put, object_path(bucket, path), bucket, path, body, opts)
  end

  @doc """
  Downloads an object and returns its bytes unchanged.

  The response is never JSON-decoded and never re-encoded — the request is made
  with `decode_body: false`, so what you get back is byte-for-byte what Storage
  stored, including bytes that are not valid UTF-8.

  ## Options

    * `:download` - `true` to ask for a `Content-Disposition: attachment`
      response, or a filename string to name the attachment.
    * `:version_id` - fetch a specific version.
    * `:token` - act as this user's JWT.
  """
  @spec download(Client.t(), String.t(), String.t(), keyword()) :: result(binary())
  def download(client, bucket, path, opts \\ []) do
    params =
      []
      |> put_param(:download, download_param(opts[:download]))
      |> put_param(:versionId, opts[:version_id])

    request =
      [params: params, decode_body: false] ++ forwarded(opts)

    with {:ok, %{body: bytes}} <-
           Client.request(client, :get, object_path(bucket, path), request) do
      {:ok, bytes}
    end
  end

  @doc """
  Lists the objects in a bucket.

  ## Options

    * `:prefix` - the folder to list. Required by the API; defaults to `""`,
      the bucket root.
    * `:limit` / `:offset` - pagination.
    * `:sort_by` - a keyword list or map with `:column` (`:name`,
      `:updated_at`, `:created_at` or `:last_accessed_at`) and `:order`
      (`:asc` or `:desc`).
    * `:search` - substring match on the object name.
    * `:token` - act as this user's JWT.

  Folder placeholders come back in the same list as real objects; see
  `AshSupabase.Storage.Object.folder?/1`.
  """
  @spec list(Client.t(), String.t(), keyword()) :: result([Object.t()])
  def list(client, bucket, opts \\ []) do
    path = @prefix <> "/object/list/" <> encode_segment(bucket)

    json =
      %{"prefix" => Keyword.get(opts, :prefix, "")}
      |> maybe_put("limit", opts[:limit])
      |> maybe_put("offset", opts[:offset])
      |> maybe_put("search", opts[:search])
      |> maybe_put("sortBy", sort_by_json(opts[:sort_by]))

    with {:ok, %{body: body}} <-
           Client.request(client, :post, path, [json: json] ++ forwarded(opts)),
         {:ok, rows} <- expect_list(body, :post, path) do
      {:ok, Object.from_json_list(rows)}
    end
  end

  @doc """
  Deletes objects in bulk.

  This is `DELETE /object/{bucket}` with a JSON body of keys — the endpoint
  storage-js's `.remove()` uses — not one request per key. Each entry is a key
  string, or a map with `:path` and `:version_id` to delete a specific version.

  Returns the rows the server deleted, which is how you tell a key that was
  removed from one that never existed.
  """
  @spec remove(Client.t(), String.t(), [String.t() | map()] | String.t(), keyword()) ::
          result([Object.t()])
  def remove(client, bucket, paths, opts \\ []) do
    path = @prefix <> "/object/" <> encode_segment(bucket)
    json = %{"prefixes" => paths |> List.wrap() |> Enum.map(&prefix_json/1)}

    with {:ok, %{body: body}} <-
           Client.request(client, :delete, path, [json: json] ++ forwarded(opts)),
         {:ok, rows} <- expect_list(body, :delete, path) do
      {:ok, Object.from_json_list(rows)}
    end
  end

  @doc """
  Moves (renames) an object.

  ## Options

    * `:destination_bucket` - move across buckets. Defaults to `bucket`.
    * `:source_version_id` - move a specific version.
    * `:token` - act as this user's JWT.
  """
  @spec move(Client.t(), String.t(), String.t(), String.t(), keyword()) ::
          result(%{id: String.t() | nil, key: String.t() | nil})
  def move(client, bucket, from, to, opts \\ []) do
    path = @prefix <> "/object/move"

    json =
      %{"bucketId" => bucket, "sourceKey" => from, "destinationKey" => to}
      |> maybe_put("destinationBucket", opts[:destination_bucket])
      |> maybe_put("sourceVersionId", opts[:source_version_id])

    with {:ok, %{body: body}} <-
           Client.request(client, :post, path, [json: json] ++ forwarded(opts)),
         {:ok, row} <- expect_map(body, :post, path) do
      {:ok, %{id: row["Id"], key: row["Key"]}}
    end
  end

  @doc """
  Copies an object.

  ## Options

    * `:destination_bucket` - copy into another bucket. Defaults to `bucket`.
    * `:source_version_id` - copy a specific version.
    * `:copy_metadata` - carry the source's metadata over. Defaults to `true`
      server-side.
    * `:metadata` - `%{"cacheControl" => ..., "mimetype" => ...}` for the copy.
    * `:upsert` - overwrite the destination if it exists.
    * `:token` - act as this user's JWT.
  """
  @spec copy(Client.t(), String.t(), String.t(), String.t(), keyword()) ::
          result(%{id: String.t() | nil, key: String.t() | nil})
  def copy(client, bucket, from, to, opts \\ []) do
    path = @prefix <> "/object/copy"

    json =
      %{"bucketId" => bucket, "sourceKey" => from, "destinationKey" => to}
      |> maybe_put("destinationBucket", opts[:destination_bucket])
      |> maybe_put("sourceVersionId", opts[:source_version_id])
      |> maybe_put("copyMetadata", opts[:copy_metadata])
      |> maybe_put("metadata", opts[:metadata])

    request =
      [json: json, headers: upsert_header(opts[:upsert]) ++ user_headers(opts)] ++ forwarded(opts)

    with {:ok, %{body: body}} <- Client.request(client, :post, path, request),
         {:ok, row} <- expect_map(body, :post, path) do
      {:ok, %{id: row["Id"], key: row["Key"]}}
    end
  end

  @doc """
  Creates a time-limited URL for a private object.

  `expires_in` is in seconds. The API replies with a *relative* path; this
  returns the absolute URL (`<project url>/storage/v1/object/sign/...`) so it
  can be handed straight to a browser.

  ## Options

    * `:download` - `true`, or a filename, to force a download.
    * `:transform` - image transformation options (`:width`, `:height`,
      `:resize`, `:format`, `:quality`).
    * `:version_id` - sign a specific version.
    * `:token` - act as this user's JWT.
  """
  @spec create_signed_url(Client.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          result(String.t())
  def create_signed_url(client, bucket, path, expires_in, opts \\ []) do
    request_path = @prefix <> "/object/sign/" <> encode_segment(bucket) <> "/" <> encode_key(path)

    json =
      %{"expiresIn" => expires_in}
      |> maybe_put("transform", transform_json(opts[:transform]))
      |> maybe_put("versionId", opts[:version_id])

    with {:ok, config} <- Client.config(client),
         {:ok, %{body: body}} <-
           Client.request(client, :post, request_path, [json: json] ++ forwarded(opts)),
         {:ok, signed} <- fetch_key(body, "signedURL", :post, request_path) do
      {:ok, absolute_url(config, signed, opts[:download])}
    end
  end

  @doc """
  Creates signed URLs for many keys in one request.

  Returns one entry per key, in the order the server sent them, as
  `%{path: key, signed_url: url_or_nil, error: reason_or_nil}` — a key that
  could not be signed (it does not exist, say) fails on its own without failing
  the call.
  """
  @spec create_signed_urls(Client.t(), String.t(), [String.t()], pos_integer(), keyword()) ::
          result([%{path: String.t() | nil, signed_url: String.t() | nil, error: term()}])
  def create_signed_urls(client, bucket, paths, expires_in, opts \\ []) do
    request_path = @prefix <> "/object/sign/" <> encode_segment(bucket)
    json = %{"expiresIn" => expires_in, "paths" => List.wrap(paths)}

    with {:ok, config} <- Client.config(client),
         {:ok, %{body: body}} <-
           Client.request(client, :post, request_path, [json: json] ++ forwarded(opts)),
         {:ok, rows} <- expect_list(body, :post, request_path) do
      {:ok, Enum.map(rows, &signed_url_row(&1, config, opts[:download]))}
    end
  end

  @doc """
  Creates a one-shot URL that lets an unauthenticated holder upload to `path`.

  Give the returned map to `upload_to_signed_url/4`, or hand `:signed_url` to a
  browser to `PUT` to directly.

  ## Options

    * `:upsert` - allow the upload to overwrite an existing object.
    * `:token` - act as this user's JWT.
  """
  @spec create_signed_upload_url(Client.t(), String.t(), String.t(), keyword()) ::
          result(signed_upload())
  def create_signed_upload_url(client, bucket, path, opts \\ []) do
    request_path =
      @prefix <> "/object/upload/sign/" <> encode_segment(bucket) <> "/" <> encode_key(path)

    request =
      [json: %{}, headers: upsert_header(opts[:upsert]) ++ user_headers(opts)] ++ forwarded(opts)

    with {:ok, config} <- Client.config(client),
         {:ok, %{body: body}} <- Client.request(client, :post, request_path, request),
         {:ok, url} <- fetch_key(body, "url", :post, request_path),
         {:ok, token} <- fetch_key(body, "token", :post, request_path) do
      {:ok,
       %{
         bucket: bucket,
         path: path,
         token: token,
         signed_url: absolute_url(config, url, nil)
       }}
    end
  end

  @doc """
  Uploads to a URL produced by `create_signed_upload_url/4`.

  `signed` is that function's return value, or any map or `{bucket, path, token}`
  tuple carrying the same three fields. The upload token authorizes the request
  by itself; the client's own credentials still ride along, because every
  request goes through `AshSupabase.Client`, and Storage ignores them here.

  Accepts the same `:content_type`, `:cache_control`, `:upsert` and `:metadata`
  options as `upload/5`.
  """
  @spec upload_to_signed_url(
          Client.t(),
          signed_upload() | map() | {String.t(), String.t(), String.t()},
          body(),
          keyword()
        ) :: result(%{key: String.t() | nil, bucket: String.t(), path: String.t()})
  def upload_to_signed_url(client, signed, body, opts \\ [])

  def upload_to_signed_url(client, {bucket, path, token}, body, opts) do
    upload_to_signed_url(client, %{bucket: bucket, path: path, token: token}, body, opts)
  end

  def upload_to_signed_url(client, %{bucket: bucket, path: path, token: token}, body, opts) do
    request_path =
      @prefix <> "/object/upload/sign/" <> encode_segment(bucket) <> "/" <> encode_key(path)

    with {:ok, bytes} <- read_body(body) do
      request =
        [
          body: bytes,
          params: [{"token", token}],
          headers: upload_headers(opts)
        ] ++ forwarded(opts)

      with {:ok, %{body: response_body}} <-
             Client.request(client, :put, request_path, request),
           {:ok, row} <- expect_map(response_body, :put, request_path) do
        {:ok, %{key: row["Key"], bucket: bucket, path: path}}
      end
    end
  end

  # ----------------------------------------------------------------------------
  # URLs
  # ----------------------------------------------------------------------------

  @doc """
  Builds the public URL of an object. Makes no request.

  Only works for objects in a bucket created with `public: true`; for a private
  bucket use `create_signed_url/5`. Because nothing is checked, this is a pure
  function — it raises `AshSupabase.Error.Configuration` only if the client
  itself cannot be resolved.

  Pass `:download` (`true`, or a filename) to add the query parameter that makes
  a browser save the file instead of rendering it.

      iex> client = [url: "https://abcdefgh.supabase.co", api_key: "anon"]
      iex> AshSupabase.Storage.public_url(client, "avatars", "ada/cat.png")
      "https://abcdefgh.supabase.co/storage/v1/object/public/avatars/ada/cat.png"

      iex> client = [url: "https://abcdefgh.supabase.co", api_key: "anon"]
      iex> AshSupabase.Storage.public_url(client, "avatars", "ada/my cat.png", download: true)
      "https://abcdefgh.supabase.co/storage/v1/object/public/avatars/ada/my%20cat.png?download="
  """
  @spec public_url(Client.t(), String.t(), String.t(), keyword()) :: String.t()
  def public_url(client, bucket, path, opts \\ []) do
    config = Client.config!(client)

    url =
      Config.storage_url(config) <>
        "/object/public/" <> encode_segment(bucket) <> "/" <> encode_key(path)

    case download_param(opts[:download]) do
      nil -> url
      value -> url <> "?" <> URI.encode_query([{"download", value}])
    end
  end

  @doc """
  Percent-encodes an object key for use in a URL path.

  `/` is left alone because it separates folders; every character outside the
  unreserved set (`A-Z a-z 0-9 - _ . ~`) is escaped, so a key can safely contain
  spaces, `?`, `#`, `%` or non-ASCII text.

      iex> AshSupabase.Storage.encode_key("ada/my cat (1).png")
      "ada/my%20cat%20%281%29.png"

      iex> AshSupabase.Storage.encode_key("100%/a?b#c.txt")
      "100%25/a%3Fb%23c.txt"
  """
  @spec encode_key(String.t()) :: String.t()
  def encode_key(key) when is_binary(key) do
    key
    |> String.split("/")
    |> Enum.map_join("/", &encode_segment/1)
  end

  @doc """
  Percent-encodes a single path segment, escaping `/` as well.

      iex> AshSupabase.Storage.encode_segment("my bucket/x")
      "my%20bucket%2Fx"
  """
  @spec encode_segment(String.t()) :: String.t()
  def encode_segment(segment) when is_binary(segment),
    do: URI.encode(segment, &URI.char_unreserved?/1)

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------

  defp do_upload(client, method, request_path, bucket, path, body, opts) do
    with {:ok, bytes} <- read_body(body) do
      request = [body: bytes, headers: upload_headers(opts)] ++ forwarded(opts)

      with {:ok, %{body: response_body}} <- Client.request(client, method, request_path, request),
           {:ok, row} <- expect_map(response_body, method, request_path) do
        {:ok, %{id: row["Id"], key: row["Key"], bucket: bucket, path: path}}
      end
    end
  end

  defp read_body(binary) when is_binary(binary), do: {:ok, binary}

  defp read_body({:file, file}) do
    case File.read(file) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, %File.Error{reason: reason, action: "read file", path: file}}
    end
  end

  defp upload_headers(opts) do
    [{"content-type", Keyword.get(opts, :content_type, @default_content_type)}] ++
      cache_control_header(opts[:cache_control]) ++
      upsert_header(opts[:upsert]) ++
      metadata_header(opts[:metadata]) ++
      user_headers(opts)
  end

  defp cache_control_header(nil), do: []

  defp cache_control_header(seconds) when is_integer(seconds),
    do: [{"cache-control", "max-age=#{seconds}"}]

  defp cache_control_header(value) when is_binary(value), do: [{"cache-control", value}]

  defp upsert_header(nil), do: []
  defp upsert_header(value) when is_boolean(value), do: [{"x-upsert", to_string(value)}]

  defp metadata_header(nil), do: []

  # storage-js base64-encodes the JSON so the value survives being a header.
  defp metadata_header(metadata) when is_map(metadata),
    do: [{"x-metadata", Base.encode64(Jason.encode!(metadata))}]

  defp user_headers(opts) do
    case Keyword.get(opts, :headers, []) do
      headers when is_map(headers) -> Map.to_list(headers)
      headers when is_list(headers) -> headers
    end
  end

  # `:headers` is applied by each caller alongside its own, so it must not be
  # forwarded a second time.
  defp forwarded(opts), do: Keyword.take(opts, [:token, :req_options])

  defp bucket_path(bucket), do: @prefix <> "/bucket/" <> encode_segment(bucket)

  defp object_path(bucket, path),
    do: @prefix <> "/object/" <> encode_segment(bucket) <> "/" <> encode_key(path)

  defp put_param(params, _key, nil), do: params
  defp put_param(params, key, value), do: params ++ [{key, value}]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # `download=` with no value is how Storage is asked for an attachment whose
  # name it should pick itself.
  defp download_param(nil), do: nil
  defp download_param(true), do: ""
  defp download_param(false), do: nil
  defp download_param(name) when is_binary(name), do: name

  defp sort_by_json(nil), do: nil

  defp sort_by_json(sort_by) do
    map = Enum.into(sort_by, %{}, fn {key, value} -> {to_string(key), to_string(value)} end)
    Map.take(map, ["column", "order"])
  end

  defp transform_json(nil), do: nil

  defp transform_json(transform),
    do: Enum.into(transform, %{}, fn {key, value} -> {to_string(key), value} end)

  defp prefix_json(path) when is_binary(path), do: path

  defp prefix_json(entry) when is_map(entry) do
    %{"path" => entry[:path] || entry["path"]}
    |> maybe_put("versionId", entry[:version_id] || entry["versionId"])
  end

  defp signed_url_row(row, config, download) when is_map(row) do
    %{
      path: row["path"],
      signed_url: row["signedURL"] && absolute_url(config, row["signedURL"], download),
      error: row["error"]
    }
  end

  # The API returns "/object/sign/<bucket>/<key>?token=<jwt>" — a path, not a
  # URL. Prefixing the project's storage base is what makes it usable.
  defp absolute_url(config, signed, download) do
    base = Config.storage_url(config)

    url =
      case signed do
        "/" <> _ -> base <> signed
        other -> base <> "/" <> other
      end

    case download_param(download) do
      nil -> url
      value -> url <> separator(url) <> URI.encode_query([{"download", value}])
    end
  end

  defp separator(url), do: if(String.contains?(url, "?"), do: "&", else: "?")

  defp fetch_key(body, key, method, path) when is_map(body) do
    case Map.fetch(body, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, unexpected_body(body, "a #{key} field", method, path)}
    end
  end

  defp fetch_key(body, key, method, path),
    do: {:error, unexpected_body(body, "a #{key} field", method, path)}

  defp expect_map(body, _method, _path) when is_map(body), do: {:ok, body}

  defp expect_map(body, method, path),
    do: {:error, unexpected_body(body, "an object", method, path)}

  defp expect_list(body, _method, _path) when is_list(body), do: {:ok, body}

  defp expect_list(body, method, path),
    do: {:error, unexpected_body(body, "a list of rows", method, path)}

  defp unexpected_body(body, expected, method, path) do
    Error.Request.exception(
      status: 200,
      supabase_message: "unexpected Storage response body, expected #{expected}",
      body: body,
      method: method,
      request_path: path
    )
  end
end
