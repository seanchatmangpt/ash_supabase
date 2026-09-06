defmodule AshSupabase.StorageTest do
  use AshSupabase.Case, async: true

  alias AshSupabase.Storage
  alias AshSupabase.Storage.Bucket
  alias AshSupabase.Storage.Object

  doctest AshSupabase.Storage
  doctest AshSupabase.Storage.Bucket
  doctest AshSupabase.Storage.Object

  @bucket_json %{
    "id" => "avatars",
    "type" => "STANDARD",
    "name" => "avatars",
    "owner" => "4d56e902-0be5-4a0c-b0a1-000000000000",
    "public" => false,
    "file_size_limit" => 1_000_000,
    "allowed_mime_types" => ["image/png", "image/jpeg"],
    "created_at" => "2021-02-17T04:43:32.770206+00:00",
    "updated_at" => "2021-02-17T04:43:32.770206+00:00"
  }

  @object_json %{
    "name" => "cat.png",
    "id" => "8b2c1e9e-0000-4000-8000-000000000000",
    "bucket_id" => "avatars",
    "owner" => "4d56e902-0be5-4a0c-b0a1-000000000000",
    "updated_at" => "2021-04-06T16:51:19.077Z",
    "created_at" => "2021-04-06T16:51:19.077Z",
    "last_accessed_at" => "2021-04-06T16:51:19.077Z",
    "metadata" => %{"size" => 1024, "mimetype" => "image/png"}
  }

  # Deliberately not valid UTF-8: a lone 0xFF byte and a NUL. If anything on the
  # path decodes or re-encodes the payload, these bytes do not survive.
  @binary <<0xFF, 0xD8, 0xFF, 0x00, 0x01, 0x80, 0xFE>>

  describe "list_buckets/2" do
    test "GETs /storage/v1/bucket with the documented query parameters" do
      capture = expect_request(fn conn -> Req.Test.json(conn, [@bucket_json]) end)

      assert {:ok, [%Bucket{} = bucket]} =
               Storage.list_buckets(TestClient,
                 limit: 10,
                 offset: 5,
                 sort_column: :name,
                 sort_order: :desc,
                 search: "av"
               )

      conn = capture.()
      assert conn.method == "GET"
      assert conn.request_path == "/storage/v1/bucket"

      assert query_params(conn) == [
               {"limit", "10"},
               {"offset", "5"},
               {"sortColumn", "name"},
               {"sortOrder", "desc"},
               {"search", "av"}
             ]

      assert header(conn, "apikey") == "test-anon-key"
      assert header(conn, "authorization") == "Bearer test-anon-key"
      assert request_body(conn) == nil

      assert bucket.id == "avatars"
      assert bucket.name == "avatars"
      assert bucket.type == "STANDARD"
      assert bucket.public == false
      assert bucket.file_size_limit == 1_000_000
      assert bucket.allowed_mime_types == ["image/png", "image/jpeg"]
      assert bucket.created_at == ~U[2021-02-17 04:43:32.770206Z]
      assert bucket.updated_at == ~U[2021-02-17 04:43:32.770206Z]
    end

    test "sends no query string when no options are given" do
      capture = expect_request(fn conn -> Req.Test.json(conn, []) end)

      assert {:ok, []} = Storage.list_buckets(TestClient)

      assert capture.().query_string == ""
    end

    test "errors when the body is not a list" do
      expect_request(fn conn -> Req.Test.json(conn, %{"unexpected" => true}) end)

      assert {:error, %AshSupabase.Error.Request{} = error} = Storage.list_buckets(TestClient)
      assert error.supabase_message =~ "expected a list of rows"
    end
  end

  describe "get_bucket/3" do
    test "GETs /storage/v1/bucket/{id}" do
      capture = expect_request(fn conn -> Req.Test.json(conn, @bucket_json) end)

      assert {:ok, %Bucket{id: "avatars"}} = Storage.get_bucket(TestClient, "avatars")

      conn = capture.()
      assert conn.method == "GET"
      assert conn.request_path == "/storage/v1/bucket/avatars"
    end

    test "percent-encodes the bucket id" do
      capture = expect_request(fn conn -> Req.Test.json(conn, @bucket_json) end)

      assert {:ok, %Bucket{}} = Storage.get_bucket(TestClient, "my bucket")

      assert capture.().request_path == "/storage/v1/bucket/my%20bucket"
    end
  end

  describe "create_bucket/3" do
    test "POSTs the documented body and returns the bucket name" do
      capture = expect_request(fn conn -> Req.Test.json(conn, %{"name" => "avatars"}) end)

      assert {:ok, "avatars"} =
               Storage.create_bucket(TestClient, "avatars",
                 id: "avatars",
                 public: true,
                 type: "STANDARD",
                 file_size_limit: 1_000_000,
                 allowed_mime_types: ["image/png"]
               )

      conn = capture.()
      assert conn.method == "POST"
      assert conn.request_path == "/storage/v1/bucket"

      assert request_body(conn) == %{
               "name" => "avatars",
               "id" => "avatars",
               "public" => true,
               "type" => "STANDARD",
               "file_size_limit" => 1_000_000,
               "allowed_mime_types" => ["image/png"]
             }
    end

    test "omits options that were not given" do
      capture = expect_request(fn conn -> Req.Test.json(conn, %{"name" => "avatars"}) end)

      assert {:ok, "avatars"} = Storage.create_bucket(TestClient, "avatars")
      assert request_body(capture.()) == %{"name" => "avatars"}
    end
  end

  describe "update_bucket/3" do
    test "PUTs only the settings that were given" do
      capture =
        expect_request(fn conn -> Req.Test.json(conn, %{"message" => "Successfully updated"}) end)

      assert :ok = Storage.update_bucket(TestClient, "avatars", public: false)

      conn = capture.()
      assert conn.method == "PUT"
      assert conn.request_path == "/storage/v1/bucket/avatars"
      assert request_body(conn) == %{"public" => false}
    end

    test "refuses an empty update without making a request" do
      assert {:error, %AshSupabase.Error.Configuration{} = error} =
               Storage.update_bucket(TestClient, "avatars")

      assert Exception.message(error) =~ ":public"
    end
  end

  describe "delete_bucket/3 and empty_bucket/3" do
    test "DELETEs /storage/v1/bucket/{id}" do
      capture =
        expect_request(fn conn -> Req.Test.json(conn, %{"message" => "Successfully deleted"}) end)

      assert :ok = Storage.delete_bucket(TestClient, "avatars")

      conn = capture.()
      assert conn.method == "DELETE"
      assert conn.request_path == "/storage/v1/bucket/avatars"
    end

    test "POSTs /storage/v1/bucket/{id}/empty" do
      capture = expect_request(fn conn -> Req.Test.json(conn, %{"message" => "queued"}) end)

      assert :ok = Storage.empty_bucket(TestClient, "avatars")

      conn = capture.()
      assert conn.method == "POST"
      assert conn.request_path == "/storage/v1/bucket/avatars/empty"
    end
  end

  describe "upload/5" do
    test "POSTs raw bytes with the documented headers" do
      capture =
        expect_request(fn conn ->
          Req.Test.json(conn, %{"Id" => "8b2c1e9e", "Key" => "avatars/ada/cat.png"})
        end)

      assert {:ok, result} =
               Storage.upload(TestClient, "avatars", "ada/cat.png", @binary,
                 content_type: "image/png",
                 cache_control: 3600,
                 upsert: true,
                 metadata: %{"alt" => "a cat"}
               )

      assert result == %{
               id: "8b2c1e9e",
               key: "avatars/ada/cat.png",
               bucket: "avatars",
               path: "ada/cat.png"
             }

      conn = capture.()
      assert conn.method == "POST"
      assert conn.request_path == "/storage/v1/object/avatars/ada/cat.png"
      assert conn.query_string == ""
      assert header(conn, "content-type") == "image/png"
      assert header(conn, "cache-control") == "max-age=3600"
      assert header(conn, "x-upsert") == "true"
      assert header(conn, "x-metadata") == Base.encode64(~s({"alt":"a cat"}))
      assert raw_body(conn) == @binary
    end

    test "defaults the content type and omits optional headers" do
      capture = expect_request(fn conn -> Req.Test.json(conn, %{"Id" => "1", "Key" => "b/a"}) end)

      assert {:ok, _} = Storage.upload(TestClient, "b", "a", "hello")

      conn = capture.()
      assert header(conn, "content-type") == "application/octet-stream"
      assert header(conn, "cache-control") == nil
      assert header(conn, "x-upsert") == nil
      assert header(conn, "x-metadata") == nil
      assert raw_body(conn) == "hello"
    end

    test "percent-encodes each path segment but keeps the separators" do
      capture = expect_request(fn conn -> Req.Test.json(conn, %{"Id" => "1", "Key" => "k"}) end)

      assert {:ok, _} = Storage.upload(TestClient, "my bucket", "a b/c?d#e.png", "x")

      assert capture.().request_path == "/storage/v1/object/my%20bucket/a%20b/c%3Fd%23e.png"
    end

    test "uploads a file from disk byte for byte" do
      path =
        Path.join(
          System.tmp_dir!(),
          "ash_supabase_upload_#{System.unique_integer([:positive])}.bin"
        )

      File.write!(path, @binary)
      on_exit(fn -> File.rm(path) end)

      capture =
        expect_request(fn conn -> Req.Test.json(conn, %{"Id" => "1", "Key" => "b/cat"}) end)

      assert {:ok, %{key: "b/cat"}} =
               Storage.upload(TestClient, "b", "cat", {:file, path}, content_type: "image/png")

      conn = capture.()
      assert raw_body(conn) == @binary
      assert header(conn, "content-type") == "image/png"
    end

    test "returns a File.Error when the file cannot be read" do
      assert {:error, %File.Error{reason: :enoent}} =
               Storage.upload(TestClient, "b", "cat", {:file, "/nope/missing.png"})
    end

    test "surfaces a real Storage error body" do
      expect_request(fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "statusCode" => "400",
          "error" => "Duplicate",
          "message" => "The resource already exists",
          "code" => "ResourceAlreadyExists"
        })
      end)

      assert {:error, %AshSupabase.Error.Request{} = error} =
               Storage.upload(TestClient, "avatars", "ada/cat.png", "x")

      assert error.status == 400
      assert error.code == "ResourceAlreadyExists"
      assert error.supabase_message == "The resource already exists"
      assert error.body["statusCode"] == "400"
      assert error.request_path == "/storage/v1/object/avatars/ada/cat.png"
      assert Exception.message(error) =~ "status 400"
    end
  end

  describe "update/5" do
    test "PUTs to the object path" do
      capture =
        expect_request(fn conn ->
          Req.Test.json(conn, %{"Id" => "8b2c1e9e", "Key" => "avatars/ada/cat.png"})
        end)

      assert {:ok, %{key: "avatars/ada/cat.png"}} =
               Storage.update(TestClient, "avatars", "ada/cat.png", "new bytes",
                 content_type: "image/png"
               )

      conn = capture.()
      assert conn.method == "PUT"
      assert conn.request_path == "/storage/v1/object/avatars/ada/cat.png"
      assert raw_body(conn) == "new bytes"
    end
  end

  describe "download/4" do
    test "returns the raw bytes unchanged" do
      capture =
        expect_request(fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("image/png")
          |> Plug.Conn.send_resp(200, @binary)
        end)

      assert {:ok, bytes} = Storage.download(TestClient, "avatars", "ada/cat.png")
      assert bytes == @binary
      refute String.valid?(bytes)

      conn = capture.()
      assert conn.method == "GET"
      assert conn.request_path == "/storage/v1/object/avatars/ada/cat.png"
      assert conn.query_string == ""
    end

    test "sends download and versionId query parameters" do
      capture =
        expect_request(fn conn -> Plug.Conn.send_resp(conn, 200, "bytes") end)

      assert {:ok, "bytes"} =
               Storage.download(TestClient, "avatars", "cat.png",
                 download: "kitten.png",
                 version_id: "v1"
               )

      assert query_params(capture.()) == [{"download", "kitten.png"}, {"versionId", "v1"}]
    end

    test "download: true asks for an attachment with no name" do
      capture = expect_request(fn conn -> Plug.Conn.send_resp(conn, 200, "bytes") end)

      assert {:ok, "bytes"} = Storage.download(TestClient, "avatars", "cat.png", download: true)
      assert capture.().query_string == "download="
    end

    test "reports transport failures" do
      expect_request(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %AshSupabase.Error.Transport{} = error} =
               Storage.download(TestClient, "avatars", "cat.png")

      assert Exception.message(error) =~ "timeout"
    end
  end

  describe "list/3" do
    test "POSTs /object/list/{bucket} with prefix, limit, offset, sortBy and search" do
      capture =
        expect_request(fn conn ->
          Req.Test.json(conn, [
            @object_json,
            %{
              "name" => "photos",
              "id" => nil,
              "created_at" => nil,
              "updated_at" => nil,
              "last_accessed_at" => nil,
              "metadata" => nil
            }
          ])
        end)

      assert {:ok, [%Object{} = object, folder]} =
               Storage.list(TestClient, "avatars",
                 prefix: "ada",
                 limit: 100,
                 offset: 20,
                 search: "cat",
                 sort_by: [column: :updated_at, order: :desc]
               )

      conn = capture.()
      assert conn.method == "POST"
      assert conn.request_path == "/storage/v1/object/list/avatars"

      assert request_body(conn) == %{
               "prefix" => "ada",
               "limit" => 100,
               "offset" => 20,
               "search" => "cat",
               "sortBy" => %{"column" => "updated_at", "order" => "desc"}
             }

      assert object.name == "cat.png"
      assert object.bucket_id == "avatars"
      assert object.created_at == ~U[2021-04-06 16:51:19.077Z]
      assert Object.size(object) == 1024
      assert Object.mime_type(object) == "image/png"
      refute Object.folder?(object)

      assert folder.name == "photos"
      assert folder.created_at == nil
      assert Object.folder?(folder)
    end

    test "defaults the required prefix to the bucket root" do
      capture = expect_request(fn conn -> Req.Test.json(conn, []) end)

      assert {:ok, []} = Storage.list(TestClient, "avatars")
      assert request_body(capture.()) == %{"prefix" => ""}
    end
  end

  describe "remove/4" do
    test "DELETEs /object/{bucket} with a prefixes body" do
      capture = expect_request(fn conn -> Req.Test.json(conn, [@object_json]) end)

      assert {:ok, [%Object{name: "cat.png"}]} =
               Storage.remove(TestClient, "avatars", [
                 "ada/cat.png",
                 %{path: "ada/dog.png", version_id: "v9"}
               ])

      conn = capture.()
      assert conn.method == "DELETE"
      assert conn.request_path == "/storage/v1/object/avatars"

      assert request_body(conn) == %{
               "prefixes" => [
                 "ada/cat.png",
                 %{"path" => "ada/dog.png", "versionId" => "v9"}
               ]
             }
    end

    test "accepts a single key and never percent-encodes body keys" do
      capture = expect_request(fn conn -> Req.Test.json(conn, []) end)

      assert {:ok, []} = Storage.remove(TestClient, "avatars", "a b/c?d.png")
      assert request_body(capture.()) == %{"prefixes" => ["a b/c?d.png"]}
    end
  end

  describe "move/5 and copy/5" do
    test "move POSTs /object/move" do
      capture =
        expect_request(fn conn ->
          Req.Test.json(conn, %{
            "message" => "Successfully moved",
            "Id" => "8b2c1e9e",
            "Key" => "ada/kitten.png"
          })
        end)

      assert {:ok, %{id: "8b2c1e9e", key: "ada/kitten.png"}} =
               Storage.move(TestClient, "avatars", "ada/cat.png", "ada/kitten.png",
                 destination_bucket: "archive",
                 source_version_id: "v1"
               )

      conn = capture.()
      assert conn.method == "POST"
      assert conn.request_path == "/storage/v1/object/move"

      assert request_body(conn) == %{
               "bucketId" => "avatars",
               "sourceKey" => "ada/cat.png",
               "destinationKey" => "ada/kitten.png",
               "destinationBucket" => "archive",
               "sourceVersionId" => "v1"
             }
    end

    test "copy POSTs /object/copy and honors x-upsert" do
      capture =
        expect_request(fn conn ->
          Req.Test.json(conn, %{"Id" => "8b2c1e9e", "Key" => "archive/ada/cat.png"})
        end)

      assert {:ok, %{key: "archive/ada/cat.png"}} =
               Storage.copy(TestClient, "avatars", "ada/cat.png", "ada/cat.png",
                 destination_bucket: "archive",
                 copy_metadata: false,
                 metadata: %{"mimetype" => "image/png"},
                 upsert: true
               )

      conn = capture.()
      assert conn.request_path == "/storage/v1/object/copy"
      assert header(conn, "x-upsert") == "true"

      assert request_body(conn) == %{
               "bucketId" => "avatars",
               "sourceKey" => "ada/cat.png",
               "destinationKey" => "ada/cat.png",
               "destinationBucket" => "archive",
               "copyMetadata" => false,
               "metadata" => %{"mimetype" => "image/png"}
             }
    end
  end

  describe "create_signed_url/5" do
    test "POSTs the expiry and returns an absolute URL" do
      capture =
        expect_request(fn conn ->
          Req.Test.json(conn, %{
            "signedURL" => "/object/sign/avatars/ada/cat.png?token=eyJhbGciOi"
          })
        end)

      assert {:ok, url} =
               Storage.create_signed_url(TestClient, "avatars", "ada/cat.png", 3600,
                 transform: [width: 100, height: 100],
                 version_id: "v1"
               )

      assert url ==
               "https://test.supabase.co/storage/v1/object/sign/avatars/ada/cat.png?token=eyJhbGciOi"

      conn = capture.()
      assert conn.method == "POST"
      assert conn.request_path == "/storage/v1/object/sign/avatars/ada/cat.png"

      assert request_body(conn) == %{
               "expiresIn" => 3600,
               "transform" => %{"width" => 100, "height" => 100},
               "versionId" => "v1"
             }
    end

    test "appends a download parameter to the signed URL" do
      expect_request(fn conn ->
        Req.Test.json(conn, %{"signedURL" => "/object/sign/avatars/cat.png?token=abc"})
      end)

      assert {:ok, url} =
               Storage.create_signed_url(TestClient, "avatars", "cat.png", 60,
                 download: "kitten.png"
               )

      assert url ==
               "https://test.supabase.co/storage/v1/object/sign/avatars/cat.png?token=abc&download=kitten.png"
    end

    test "errors when the response has no signedURL" do
      expect_request(fn conn -> Req.Test.json(conn, %{"oops" => true}) end)

      assert {:error, %AshSupabase.Error.Request{} = error} =
               Storage.create_signed_url(TestClient, "avatars", "cat.png", 60)

      assert error.supabase_message =~ "signedURL"
    end
  end

  describe "create_signed_urls/5" do
    test "POSTs the paths and absolutizes each successful row" do
      capture =
        expect_request(fn conn ->
          Req.Test.json(conn, [
            %{
              "error" => nil,
              "path" => "ada/cat.png",
              "signedURL" => "/object/sign/avatars/ada/cat.png?token=abc"
            },
            %{"error" => "Object not found", "path" => "ada/gone.png", "signedURL" => nil}
          ])
        end)

      assert {:ok, [ok_row, error_row]} =
               Storage.create_signed_urls(
                 TestClient,
                 "avatars",
                 ["ada/cat.png", "ada/gone.png"],
                 60
               )

      assert ok_row == %{
               path: "ada/cat.png",
               signed_url:
                 "https://test.supabase.co/storage/v1/object/sign/avatars/ada/cat.png?token=abc",
               error: nil
             }

      assert error_row == %{path: "ada/gone.png", signed_url: nil, error: "Object not found"}

      conn = capture.()
      assert conn.request_path == "/storage/v1/object/sign/avatars"

      assert request_body(conn) == %{
               "expiresIn" => 60,
               "paths" => ["ada/cat.png", "ada/gone.png"]
             }
    end
  end

  describe "signed upload URLs" do
    test "create_signed_upload_url/4 returns the absolute URL and the token" do
      capture =
        expect_request(fn conn ->
          Req.Test.json(conn, %{
            "url" => "/object/upload/sign/avatars/ada/cat.png?token=eyJ",
            "token" => "eyJ"
          })
        end)

      assert {:ok, signed} =
               Storage.create_signed_upload_url(TestClient, "avatars", "ada/cat.png",
                 upsert: true
               )

      assert signed == %{
               bucket: "avatars",
               path: "ada/cat.png",
               token: "eyJ",
               signed_url:
                 "https://test.supabase.co/storage/v1/object/upload/sign/avatars/ada/cat.png?token=eyJ"
             }

      conn = capture.()
      assert conn.method == "POST"
      assert conn.request_path == "/storage/v1/object/upload/sign/avatars/ada/cat.png"
      assert header(conn, "x-upsert") == "true"
      assert request_body(conn) == %{}
    end

    test "upload_to_signed_url/4 PUTs the bytes with the token in the query string" do
      capture =
        expect_request(fn conn -> Req.Test.json(conn, %{"Key" => "avatars/ada/cat.png"}) end)

      signed = %{bucket: "avatars", path: "ada/cat.png", token: "eyJ"}

      assert {:ok, %{key: "avatars/ada/cat.png", bucket: "avatars", path: "ada/cat.png"}} =
               Storage.upload_to_signed_url(TestClient, signed, @binary,
                 content_type: "image/png"
               )

      conn = capture.()
      assert conn.method == "PUT"
      assert conn.request_path == "/storage/v1/object/upload/sign/avatars/ada/cat.png"
      assert conn.query_string == "token=eyJ"
      assert header(conn, "content-type") == "image/png"
      assert raw_body(conn) == @binary
    end

    test "upload_to_signed_url/4 also accepts a {bucket, path, token} tuple" do
      capture = expect_request(fn conn -> Req.Test.json(conn, %{"Key" => "b/a"}) end)

      assert {:ok, %{key: "b/a"}} =
               Storage.upload_to_signed_url(TestClient, {"b", "a", "tok"}, "x")

      conn = capture.()
      assert conn.request_path == "/storage/v1/object/upload/sign/b/a"
      assert conn.query_string == "token=tok"
    end
  end

  describe "public_url/4" do
    test "builds the public URL without making a request" do
      assert Storage.public_url(TestClient, "avatars", "ada/cat.png") ==
               "https://test.supabase.co/storage/v1/object/public/avatars/ada/cat.png"
    end

    test "percent-encodes segments and appends a download name" do
      assert Storage.public_url(TestClient, "my bucket", "a b/c?d.png", download: "cat.png") ==
               "https://test.supabase.co/storage/v1/object/public/my%20bucket/a%20b/c%3Fd.png?download=cat.png"
    end
  end
end
