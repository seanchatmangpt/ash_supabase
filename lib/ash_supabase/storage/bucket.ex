defmodule AshSupabase.Storage.Bucket do
  @moduledoc """
  A Storage bucket row, as returned by `GET /storage/v1/bucket` and
  `GET /storage/v1/bucket/{id}`.

  The API returns timestamps as ISO 8601 strings with an offset
  (`"2021-02-17T04:43:32.770206+00:00"`). `from_json/1` converts them to
  `DateTime` in UTC so that comparing two buckets never depends on the offset
  the server happened to send. Anything unparseable — including `nil`, which is
  what the API sends for a bucket row embedded in an object listing — becomes
  `nil` rather than an error, because a bucket you can otherwise use is not
  worth failing on because of one field.

  ## Fields

    * `:id` - the bucket id, e.g. `"avatars"`. This is what every object path
      is scoped by; it defaults to `:name` when a bucket is created.
    * `:name` - the bucket name.
    * `:type` - `"STANDARD"` or `"ANALYTICS"`. Older server versions omit it.
    * `:owner` - the uuid of the user that created the bucket.
    * `:public` - whether objects are readable through
      `/storage/v1/object/public/...` without a token.
    * `:file_size_limit` - the per-object limit in bytes, or `nil` for none.
      The API accepts (and may return) a string such as `"5MB"`, so this is
      left exactly as sent.
    * `:allowed_mime_types` - a list of permitted MIME types, or `nil`.
    * `:created_at` / `:updated_at` - `DateTime` in UTC, or `nil`.

  ## Example

      iex> alias AshSupabase.Storage.Bucket
      iex> bucket = Bucket.from_json(%{"id" => "avatars", "public" => true, "created_at" => "2021-02-17T04:43:32.770206+00:00"})
      iex> {bucket.id, bucket.public, bucket.created_at}
      {"avatars", true, ~U[2021-02-17 04:43:32.770206Z]}
  """

  @typedoc "A Storage bucket."
  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          type: String.t() | nil,
          owner: String.t() | nil,
          public: boolean() | nil,
          file_size_limit: integer() | String.t() | nil,
          allowed_mime_types: [String.t()] | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :name,
    :type,
    :owner,
    :public,
    :file_size_limit,
    :allowed_mime_types,
    :created_at,
    :updated_at
  ]

  @doc """
  Builds a bucket from a decoded JSON object.

  Missing keys become `nil`, so this works on the trimmed bucket rows that are
  embedded in object listings as well as on full bucket responses. `nil` maps
  to `nil` for the same reason.

      iex> AshSupabase.Storage.Bucket.from_json(%{"created_at" => "not a timestamp"}).created_at
      nil

      iex> AshSupabase.Storage.Bucket.from_json(nil)
      nil
  """
  @spec from_json(map() | nil) :: t() | nil
  def from_json(nil), do: nil

  def from_json(json) when is_map(json) do
    %__MODULE__{
      id: json["id"],
      name: json["name"],
      type: json["type"],
      owner: json["owner"],
      public: json["public"],
      file_size_limit: json["file_size_limit"],
      allowed_mime_types: json["allowed_mime_types"],
      created_at: to_datetime(json["created_at"]),
      updated_at: to_datetime(json["updated_at"])
    }
  end

  @doc """
  Builds a list of buckets from a decoded JSON array.

      iex> AshSupabase.Storage.Bucket.from_json_list([%{"id" => "avatars"}]) |> Enum.map(& &1.id)
      ["avatars"]
  """
  @spec from_json_list([map()]) :: [t()]
  def from_json_list(list) when is_list(list), do: Enum.map(list, &from_json/1)

  # Shared by Bucket and Object rather than extracted, because a timestamp that
  # cannot be parsed must never take down a response that is otherwise usable.
  defp to_datetime(%DateTime{} = datetime), do: datetime

  defp to_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp to_datetime(_other), do: nil
end
