defmodule AshSupabase.Storage.Object do
  @moduledoc """
  An object row, as returned by `POST /storage/v1/object/list/{bucket}` and by
  the bulk delete endpoint.

  Listing a bucket returns *two* kinds of row from the same array: real objects,
  and the synthetic folder rows that stand for a path prefix. A folder row has
  `id: nil` and null timestamps, which is why `folder?/1` exists — there is no
  type discriminator on the wire.

  Timestamps are parsed to `DateTime` in UTC and anything unparseable (including
  the nulls on folder rows) becomes `nil`; see `AshSupabase.Storage.Bucket` for
  why.

  ## Fields

    * `:name` - the object key *relative to the prefix that was listed*, not the
      full key and never prefixed with the bucket.
    * `:id` - the object uuid, or `nil` for a folder row.
    * `:bucket_id` - the bucket the object lives in.
    * `:owner` / `:owner_id` - the user that last wrote the object.
    * `:version` - the storage backend's version identifier.
    * `:created_at` / `:updated_at` / `:last_accessed_at` - `DateTime` or `nil`.
    * `:metadata` - server-managed metadata, with string keys such as
      `"mimetype"`, `"size"`, `"cacheControl"` and `"eTag"`. Left as a raw map
      because the server adds keys to it over time.
    * `:user_metadata` - whatever was sent in the `x-metadata` upload header.
    * `:archived_at`, `:is_delete_marker`, `:is_versioned` - versioning fields,
      only meaningful on buckets with versioning enabled.
    * `:bucket` - the embedded bucket row (the API's `buckets` key), parsed into
      an `AshSupabase.Storage.Bucket`, or `nil` when the server did not join it.

  ## Example

      iex> alias AshSupabase.Storage.Object
      iex> object = Object.from_json(%{"name" => "cat.png", "id" => "8b2c...", "metadata" => %{"size" => 1024}})
      iex> {object.name, object.metadata["size"], Object.folder?(object)}
      {"cat.png", 1024, false}
  """

  alias AshSupabase.Storage.Bucket

  @typedoc "An object (or folder) row from a Storage listing."
  @type t :: %__MODULE__{
          name: String.t() | nil,
          id: String.t() | nil,
          bucket_id: String.t() | nil,
          owner: String.t() | nil,
          owner_id: String.t() | nil,
          version: String.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          last_accessed_at: DateTime.t() | nil,
          metadata: map() | nil,
          user_metadata: map() | nil,
          archived_at: DateTime.t() | nil,
          is_delete_marker: boolean() | nil,
          is_versioned: boolean() | nil,
          bucket: Bucket.t() | nil
        }

  defstruct [
    :name,
    :id,
    :bucket_id,
    :owner,
    :owner_id,
    :version,
    :created_at,
    :updated_at,
    :last_accessed_at,
    :metadata,
    :user_metadata,
    :archived_at,
    :is_delete_marker,
    :is_versioned,
    :bucket
  ]

  @doc """
  Builds an object from a decoded JSON object.

  Missing keys become `nil`; the only required key on the wire is `name`.

      iex> AshSupabase.Storage.Object.from_json(%{"name" => "photos", "id" => nil})
      ...> |> AshSupabase.Storage.Object.folder?()
      true
  """
  @spec from_json(map() | nil) :: t() | nil
  def from_json(nil), do: nil

  def from_json(json) when is_map(json) do
    %__MODULE__{
      name: json["name"],
      id: json["id"],
      bucket_id: json["bucket_id"],
      owner: json["owner"],
      owner_id: json["owner_id"],
      version: json["version"],
      created_at: to_datetime(json["created_at"]),
      updated_at: to_datetime(json["updated_at"]),
      last_accessed_at: to_datetime(json["last_accessed_at"]),
      metadata: json["metadata"],
      user_metadata: json["user_metadata"],
      archived_at: to_datetime(json["archived_at"]),
      is_delete_marker: json["is_delete_marker"],
      is_versioned: json["is_versioned"],
      bucket: Bucket.from_json(json["buckets"])
    }
  end

  @doc """
  Builds a list of objects from a decoded JSON array.

      iex> AshSupabase.Storage.Object.from_json_list([%{"name" => "cat.png"}]) |> Enum.map(& &1.name)
      ["cat.png"]
  """
  @spec from_json_list([map()]) :: [t()]
  def from_json_list(list) when is_list(list), do: Enum.map(list, &from_json/1)

  @doc """
  Returns true when the row is a folder placeholder rather than a stored object.

  Storage synthesizes these from the path prefixes of real objects; they carry
  a name and nothing else.
  """
  @spec folder?(t()) :: boolean()
  def folder?(%__MODULE__{id: nil}), do: true
  def folder?(%__MODULE__{}), do: false

  @doc """
  The object's size in bytes, read out of `:metadata`, or `nil` if absent.

      iex> AshSupabase.Storage.Object.from_json(%{"metadata" => %{"size" => 42}})
      ...> |> AshSupabase.Storage.Object.size()
      42
  """
  @spec size(t()) :: integer() | nil
  def size(%__MODULE__{metadata: metadata}) when is_map(metadata), do: metadata["size"]
  def size(%__MODULE__{}), do: nil

  @doc """
  The object's MIME type, read out of `:metadata`, or `nil` if absent.

      iex> AshSupabase.Storage.Object.from_json(%{"metadata" => %{"mimetype" => "image/png"}})
      ...> |> AshSupabase.Storage.Object.mime_type()
      "image/png"
  """
  @spec mime_type(t()) :: String.t() | nil
  def mime_type(%__MODULE__{metadata: metadata}) when is_map(metadata), do: metadata["mimetype"]
  def mime_type(%__MODULE__{}), do: nil

  defp to_datetime(%DateTime{} = datetime), do: datetime

  defp to_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp to_datetime(_other), do: nil
end
