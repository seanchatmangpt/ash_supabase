defmodule AshSupabase.Realtime.Change do
  @moduledoc """
  A normalized Postgres change delivered over Supabase Realtime.

  The wire payload of a `postgres_changes` event nests the interesting part
  under `payload.data` and names its fields after the replication stream
  (`type`, `record`, `old_record`). This struct is the flattened, Elixir-shaped
  version of that: `:type` is an atom, and `:record`/`:old_record` are always
  maps so that callers never have to pattern match on a missing key.

  Which of the two records is populated depends on the operation:

    * `:insert` - `:record` holds the new row, `:old_record` is `%{}`.
    * `:update` - both are populated.
    * `:delete` - `:old_record` holds the deleted row, `:record` is `%{}`.

  > #### `old_record` is usually just the primary key {: .warning}
  >
  > For `UPDATE` and `DELETE`, Postgres only sends the columns covered by the
  > table's `REPLICA IDENTITY`, which defaults to the primary key. Run
  > `ALTER TABLE ... REPLICA IDENTITY FULL` if you need the whole previous row.

  `:ids` holds the server-assigned binding ids that matched this change. A
  channel with several `postgres_changes` filters uses them to tell which
  filter fired; see `AshSupabase.Realtime.Channel`.
  """

  @typedoc "The replication operation that produced the change."
  @type type :: :insert | :update | :delete

  @typedoc "A column of the table, as declared by the server for this change."
  @type column :: %{name: String.t(), type: String.t()}

  @type t :: %__MODULE__{
          type: type(),
          schema: String.t() | nil,
          table: String.t() | nil,
          record: map(),
          old_record: map(),
          columns: [column()],
          commit_timestamp: String.t() | nil,
          errors: term(),
          ids: [integer()],
          topic: String.t() | nil
        }

  defstruct [
    :type,
    :schema,
    :table,
    :commit_timestamp,
    :errors,
    :topic,
    record: %{},
    old_record: %{},
    columns: [],
    ids: []
  ]
end

defmodule AshSupabase.Realtime.Message do
  @moduledoc """
  The Phoenix Channels v1.0.0 wire envelope spoken by Supabase Realtime.

  Realtime is a Phoenix endpoint, so every text frame on
  `wss://<project>.supabase.co/realtime/v1/websocket?apikey=...&vsn=1.0.0` is a
  JSON **object** with five keys:

      {"join_ref": "1", "ref": "1", "topic": "realtime:room-1",
       "event": "phx_join", "payload": {...}}

  `vsn=1.0.0` selects this object serializer. Phoenix v2's array form
  `[join_ref, ref, topic, event, payload]` is *not* accepted by this endpoint,
  and `decode/1` rejects it with a pointed error rather than crashing.

  This module is pure: it builds and parses frames and never touches a socket.
  `AshSupabase.Realtime.Channel` decides *which* frames to send, and
  `AshSupabase.Realtime.Socket` only moves bytes.

      iex> alias AshSupabase.Realtime.Message
      iex> message = Message.join("realtime:room-1", "1",
      ...>   postgres_changes: [[event: :insert, table: "messages"]])
      iex> {:ok, json} = Message.encode(message)
      iex> Jason.decode!(json)["payload"]["config"]["postgres_changes"]
      [%{"event" => "INSERT", "schema" => "public", "table" => "messages"}]

  ## Value conversion

  Values in `record`/`old_record` are conveyed by the replication stream and
  arrive as JSON strings for many Postgres types; the accompanying
  `columns` metadata carries the declared type name for each column
  (`{"name": "id", "type": "int8"}`). `postgres_changes/2` uses that metadata to
  coerce string values, mirroring what `realtime-js` does before it invokes a
  user callback:

    * `int2`, `int4`, `int8`, `oid` - integers
    * `float4`, `float8`, `numeric` - floats
    * `bool` - `"t"`/`"true"` to `true`, `"f"`/`"false"` to `false`
    * `json`, `jsonb` - decoded JSON
    * `timestamp`, `timestamptz` - the space separator is replaced with `T` so
      the string matches what PostgREST returns
    * `_<type>` (array types) - the Postgres array literal `{1,2}` is parsed and
      each element converted as `<type>`

  Anything else, and any value that is not a string, is passed through
  untouched. The exact per-type table used by `realtime-js` is not part of the
  documented protocol, so conversion is deliberately conservative and can be
  turned off with `convert: false`, which hands you the raw wire values.
  """

  alias AshSupabase.Realtime.Change

  @vsn "1.0.0"

  @typedoc """
  A decoded frame.

  `:ref` and `:join_ref` are `nil` on server-initiated messages such as
  `postgres_changes` and `system`.
  """
  @type t :: %__MODULE__{
          join_ref: String.t() | nil,
          ref: String.t() | nil,
          topic: String.t(),
          event: String.t(),
          payload: map()
        }

  @typedoc """
  A `postgres_changes` subscription, normalized to atom keys.

  `:table` and `:filter` are optional; `:event` defaults to `"*"` and `:schema`
  to `"public"`.
  """
  @type binding :: %{
          event: String.t(),
          schema: String.t(),
          table: String.t() | nil,
          filter: String.t() | nil
        }

  @typedoc "Why a frame could not be turned into a `t:t/0` or a `t:Change.t/0`."
  @type error ::
          {:invalid_json, Jason.DecodeError.t()}
          | {:invalid_frame, String.t()}
          | {:not_a_change, term()}
          | {:unknown_change_type, term()}
          | {:encode_error, term()}

  defstruct [:join_ref, :ref, :topic, :event, payload: %{}]

  @doc """
  The Phoenix serializer version Supabase Realtime requires.

      iex> AshSupabase.Realtime.Message.vsn()
      "1.0.0"
  """
  @spec vsn() :: String.t()
  def vsn, do: @vsn

  @doc """
  Encodes a message as a JSON text frame.

  Keys whose value is `nil` are omitted, which reproduces the frames the
  official clients send (a heartbeat carries no `join_ref`, for instance).

      iex> alias AshSupabase.Realtime.Message
      iex> {:ok, json} = Message.encode(Message.heartbeat("2"))
      iex> Jason.decode!(json)
      %{"topic" => "phoenix", "event" => "heartbeat", "payload" => %{}, "ref" => "2"}
  """
  @spec encode(t()) :: {:ok, String.t()} | {:error, error()}
  def encode(%__MODULE__{} = message) do
    case Jason.encode(to_wire(message)) do
      {:ok, json} -> {:ok, json}
      {:error, error} -> {:error, {:encode_error, error}}
    end
  end

  @doc "Same as `encode/1` but raises on failure."
  @spec encode!(t()) :: String.t()
  def encode!(%__MODULE__{} = message) do
    case encode(message) do
      {:ok, json} -> json
      {:error, {:encode_error, error}} -> raise error
    end
  end

  @doc """
  Decodes a JSON text frame into a message.

  Passing an already-decoded message or map through is allowed, so callers can
  hand `decode/1` whatever they have.

      iex> alias AshSupabase.Realtime.Message
      iex> Message.decode(~s({"topic":"realtime:room-1","event":"phx_reply","ref":"1","payload":{"status":"ok"}}))
      {:ok, %Message{topic: "realtime:room-1", event: "phx_reply", ref: "1", payload: %{"status" => "ok"}}}

  The Phoenix v2 array frame format is not spoken by this endpoint and is
  reported as such rather than being silently ignored:

      iex> {:error, {:invalid_frame, message}} = AshSupabase.Realtime.Message.decode(~s(["1","1","t","e",{}]))
      iex> message =~ "vsn=1.0.0"
      true
  """
  @spec decode(binary() | map() | t()) :: {:ok, t()} | {:error, error()}
  def decode(%__MODULE__{} = message), do: {:ok, message}

  def decode(frame) when is_binary(frame) do
    case Jason.decode(frame) do
      {:ok, decoded} -> from_json(decoded)
      {:error, error} -> {:error, {:invalid_json, error}}
    end
  end

  def decode(frame) when is_map(frame), do: from_json(frame)

  def decode(frame),
    do: {:error, {:invalid_frame, "expected a JSON text frame, got: #{inspect(frame)}"}}

  @doc """
  Builds a message from an already-decoded JSON object.

  Tolerates missing `ref`/`join_ref`/`payload`, which server-initiated messages
  omit or send as `null`.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, error()}
  def from_json(%{"topic" => topic, "event" => event} = json)
      when is_binary(topic) and is_binary(event) do
    {:ok,
     %__MODULE__{
       topic: topic,
       event: event,
       ref: nilable_string(json["ref"]),
       join_ref: nilable_string(json["join_ref"]),
       payload: payload(json["payload"])
     }}
  end

  def from_json(json) when is_list(json) do
    {:error,
     {:invalid_frame,
      """
      Received a Phoenix v2 array frame [join_ref, ref, topic, event, payload]. \
      Supabase Realtime speaks the object serializer; connect with vsn=1.0.0 in \
      the websocket query string.\
      """}}
  end

  def from_json(json) when is_map(json) do
    {:error,
     {:invalid_frame, "frame is missing a string \"topic\" and \"event\": #{inspect(json)}"}}
  end

  def from_json(json),
    do: {:error, {:invalid_frame, "expected a JSON object, got: #{inspect(json)}"}}

  @doc """
  Builds the `phx_join` message for a channel.

  `ref` doubles as the `join_ref`: every later message on the channel carries it
  so the server can tell which incarnation of the channel it belongs to.

  ## Options

    * `:postgres_changes` - the subscriptions to install, each a keyword list or
      map of `:event`, `:schema`, `:table` and `:filter`. Filters live *here*,
      not in the topic string.
    * `:access_token` - the user JWT to authorize the subscription with. Only
      sent when given.
    * `:broadcast` - `ack: boolean, self: boolean`. Defaults to both `false`.
    * `:presence` - `key: String.t(), enabled: boolean`.
    * `:private` - whether the channel is authorized by RLS. Defaults to `false`.

      iex> alias AshSupabase.Realtime.Message
      iex> message = Message.join("realtime:room-1", "1",
      ...>   postgres_changes: [%{event: "*", table: "messages", filter: "room_id=eq.1"}],
      ...>   access_token: "jwt"
      ...> )
      iex> message.payload["config"]["postgres_changes"]
      [%{"event" => "*", "schema" => "public", "table" => "messages", "filter" => "room_id=eq.1"}]
      iex> message.payload["access_token"]
      "jwt"
  """
  @spec join(String.t(), String.t(), keyword()) :: t()
  def join(topic, ref, opts \\ []) when is_binary(topic) and is_binary(ref) do
    broadcast = Keyword.get(opts, :broadcast, [])
    presence = Keyword.get(opts, :presence, [])

    config = %{
      "broadcast" => %{
        "ack" => option(broadcast, :ack, false),
        "self" => option(broadcast, :self, false)
      },
      "presence" => %{
        "key" => option(presence, :key, ""),
        "enabled" => option(presence, :enabled, false)
      },
      "postgres_changes" =>
        opts
        |> Keyword.get(:postgres_changes, [])
        |> Enum.map(&encode_binding(normalize_binding(&1))),
      "private" => Keyword.get(opts, :private, false)
    }

    payload =
      case Keyword.get(opts, :access_token) do
        nil -> %{"config" => config}
        token -> %{"config" => config, "access_token" => token}
      end

    %__MODULE__{topic: topic, event: "phx_join", ref: ref, join_ref: ref, payload: payload}
  end

  @doc """
  Builds the `phx_leave` message that closes a channel.

      iex> AshSupabase.Realtime.Message.leave("realtime:room-1", "4", "1")
      %AshSupabase.Realtime.Message{topic: "realtime:room-1", event: "phx_leave", ref: "4", join_ref: "1", payload: %{}}
  """
  @spec leave(String.t(), String.t(), String.t() | nil) :: t()
  def leave(topic, ref, join_ref) when is_binary(topic) and is_binary(ref) do
    %__MODULE__{topic: topic, event: "phx_leave", ref: ref, join_ref: join_ref, payload: %{}}
  end

  @doc """
  Builds the keepalive message.

  It is sent on the connection-level `"phoenix"` topic, not on a channel topic,
  roughly every 25 seconds. The server drops connections that stop sending it.

      iex> AshSupabase.Realtime.Message.heartbeat("2")
      %AshSupabase.Realtime.Message{topic: "phoenix", event: "heartbeat", ref: "2", join_ref: nil, payload: %{}}
  """
  @spec heartbeat(String.t()) :: t()
  def heartbeat(ref) when is_binary(ref) do
    %__MODULE__{topic: "phoenix", event: "heartbeat", ref: ref, payload: %{}}
  end

  @doc """
  Builds the message that rotates the channel's JWT.

  Pushing `access_token` keeps the subscription alive across a token refresh;
  rejoining would drop and re-create the replication subscription.

      iex> AshSupabase.Realtime.Message.access_token("realtime:room-1", "3", "1", "new-jwt")
      %AshSupabase.Realtime.Message{topic: "realtime:room-1", event: "access_token", ref: "3", join_ref: "1", payload: %{"access_token" => "new-jwt"}}
  """
  @spec access_token(String.t(), String.t(), String.t() | nil, String.t()) :: t()
  def access_token(topic, ref, join_ref, token)
      when is_binary(topic) and is_binary(ref) and is_binary(token) do
    %__MODULE__{
      topic: topic,
      event: "access_token",
      ref: ref,
      join_ref: join_ref,
      payload: %{"access_token" => token}
    }
  end

  @doc """
  Normalizes a `postgres_changes` subscription given as a keyword list or map.

  Accepts atom or string keys and an atom or string event, so that
  `[event: :insert, table: "messages"]` and
  `%{"event" => "INSERT", "table" => "messages"}` mean the same thing.

      iex> AshSupabase.Realtime.Message.normalize_binding(event: :insert, table: "messages")
      %{event: "INSERT", schema: "public", table: "messages", filter: nil}
  """
  @spec normalize_binding(keyword() | map() | binding()) :: binding()
  def normalize_binding(binding) do
    %{
      event: binding |> option(:event, "*") |> normalize_event(),
      schema: option(binding, :schema, "public"),
      table: option(binding, :table, nil),
      filter: option(binding, :filter, nil)
    }
  end

  @doc """
  Turns a `postgres_changes` message into a `t:AshSupabase.Realtime.Change.t/0`.

  Accepts a decoded `t:t/0`, a raw JSON string, the `payload` map, or the inner
  `data` map, and understands both the modern envelope
  (`%{"ids" => _, "data" => _}`) and the legacy pre-`config` form where the
  event is literally `"INSERT"`/`"UPDATE"`/`"DELETE"` and the payload is the
  bare change map.

  ## Options

    * `:convert` - convert values using the `columns` type metadata. Defaults to
      `true`. See the module documentation for the exact conversions.

      iex> alias AshSupabase.Realtime.Message
      iex> {:ok, message} = Message.decode(~s({
      ...>   "topic": "realtime:room-1", "event": "postgres_changes", "ref": null,
      ...>   "payload": {"ids": [34219287], "data": {
      ...>     "schema": "public", "table": "messages", "type": "INSERT",
      ...>     "commit_timestamp": "2026-09-06T12:00:00.000Z",
      ...>     "columns": [{"name": "id", "type": "int8"}, {"name": "body", "type": "text"}],
      ...>     "record": {"id": "7", "body": "hi"}, "errors": null}}}))
      iex> {:ok, change} = Message.postgres_changes(message)
      iex> {change.type, change.table, change.record, change.old_record, change.ids}
      {:insert, "messages", %{"id" => 7, "body" => "hi"}, %{}, [34219287]}
  """
  @spec postgres_changes(t() | map() | binary(), keyword()) ::
          {:ok, Change.t()} | {:error, error()}
  def postgres_changes(message, opts \\ [])

  def postgres_changes(frame, opts) when is_binary(frame) do
    with {:ok, message} <- decode(frame), do: postgres_changes(message, opts)
  end

  def postgres_changes(%__MODULE__{event: "postgres_changes", payload: payload} = message, opts) do
    build_change(payload["data"], payload["ids"] || [], message.topic, opts)
  end

  def postgres_changes(%__MODULE__{event: event, payload: payload} = message, opts)
      when event in ["INSERT", "UPDATE", "DELETE"] do
    build_change(payload, [], message.topic, opts)
  end

  def postgres_changes(%__MODULE__{} = message, _opts), do: {:error, {:not_a_change, message}}

  def postgres_changes(%{"data" => data} = payload, opts) do
    build_change(data, payload["ids"] || [], nil, opts)
  end

  def postgres_changes(%{"type" => _} = data, opts), do: build_change(data, [], nil, opts)

  def postgres_changes(other, _opts), do: {:error, {:not_a_change, other}}

  defp build_change(data, ids, topic, opts) when is_map(data) do
    convert? = Keyword.get(opts, :convert, true)

    with {:ok, type} <- change_type(data["type"]) do
      columns = normalize_columns(data["columns"])

      {:ok,
       %Change{
         type: type,
         schema: data["schema"],
         table: data["table"],
         commit_timestamp: data["commit_timestamp"],
         columns: columns,
         record: convert_record(data["record"], columns, convert?),
         old_record: convert_record(data["old_record"], columns, convert?),
         errors: data["errors"],
         ids: ids,
         topic: topic
       }}
    end
  end

  defp build_change(data, _ids, _topic, _opts), do: {:error, {:not_a_change, data}}

  defp change_type("INSERT"), do: {:ok, :insert}
  defp change_type("UPDATE"), do: {:ok, :update}
  defp change_type("DELETE"), do: {:ok, :delete}
  defp change_type(other), do: {:error, {:unknown_change_type, other}}

  @doc """
  Normalizes the `columns` metadata to a list of `%{name: _, type: _}` maps.

      iex> AshSupabase.Realtime.Message.normalize_columns([%{"name" => "id", "type" => "int8"}])
      [%{name: "id", type: "int8"}]
  """
  @spec normalize_columns(term()) :: [Change.column()]
  def normalize_columns(columns) when is_list(columns) do
    Enum.flat_map(columns, fn
      %{"name" => name} = column -> [%{name: name, type: column["type"]}]
      %{name: name} = column -> [%{name: name, type: Map.get(column, :type)}]
      _ -> []
    end)
  end

  def normalize_columns(_), do: []

  defp convert_record(nil, _columns, _convert?), do: %{}
  defp convert_record(record, _columns, false) when is_map(record), do: record

  defp convert_record(record, columns, true) when is_map(record) do
    types = Map.new(columns, fn column -> {column.name, column.type} end)
    Map.new(record, fn {key, value} -> {key, convert_value(Map.get(types, key), value)} end)
  end

  defp convert_record(record, _columns, _convert?), do: record

  @doc """
  Converts one wire value using its declared Postgres type name.

  Only string values are touched; anything the JSON layer already typed is
  returned as-is, and an unknown type name is a pass-through.

      iex> alias AshSupabase.Realtime.Message
      iex> {Message.convert_value("int8", "7"), Message.convert_value("bool", "t")}
      {7, true}
      iex> Message.convert_value("_int4", "{1,2,3}")
      [1, 2, 3]
      iex> Message.convert_value("timestamp", "2026-09-06 12:00:00")
      "2026-09-06T12:00:00"
  """
  @spec convert_value(String.t() | nil, term()) :: term()
  def convert_value(_type, nil), do: nil

  def convert_value("_" <> element_type, value) when is_binary(value) do
    parse_array(value, element_type)
  end

  def convert_value(type, value) when is_binary(value) do
    case type do
      type when type in ["int2", "int4", "int8", "oid"] ->
        to_integer(value)

      type when type in ["float4", "float8", "numeric"] ->
        to_float(value)

      "bool" ->
        to_boolean(value)

      type when type in ["json", "jsonb"] ->
        to_json(value)

      type when type in ["timestamp", "timestamptz"] ->
        String.replace(value, " ", "T", global: false)

      _ ->
        value
    end
  end

  def convert_value(_type, value), do: value

  defp to_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> to_float(value)
    end
  end

  defp to_float(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _ -> value
    end
  end

  defp to_boolean(value) when value in ["t", "true", "TRUE"], do: true
  defp to_boolean(value) when value in ["f", "false", "FALSE"], do: false
  defp to_boolean(value), do: value

  defp to_json(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _} -> value
    end
  end

  # Postgres array literals arrive as `{1,2}`, with quoted elements when they
  # contain a comma, a quote or a brace. `NULL` is only a null when unquoted.
  defp parse_array("{}", _element_type), do: []

  defp parse_array("{" <> rest, element_type) do
    if String.ends_with?(rest, "}") do
      rest
      |> binary_part(0, byte_size(rest) - 1)
      |> split_array([], "", false, false)
      |> Enum.map(&array_element(&1, element_type))
    else
      "{" <> rest
    end
  end

  defp parse_array(value, _element_type), do: value

  defp split_array(<<>>, acc, current, _in_quotes?, quoted?) do
    Enum.reverse([{quoted?, current} | acc])
  end

  defp split_array(<<"\\", character::utf8, rest::binary>>, acc, current, true, quoted?) do
    split_array(rest, acc, current <> <<character::utf8>>, true, quoted?)
  end

  defp split_array(<<"\"", rest::binary>>, acc, current, in_quotes?, _quoted?) do
    split_array(rest, acc, current, not in_quotes?, true)
  end

  defp split_array(<<",", rest::binary>>, acc, current, false, quoted?) do
    split_array(rest, [{quoted?, current} | acc], "", false, false)
  end

  defp split_array(<<character::utf8, rest::binary>>, acc, current, in_quotes?, quoted?) do
    split_array(rest, acc, current <> <<character::utf8>>, in_quotes?, quoted?)
  end

  defp array_element({false, "NULL"}, _element_type), do: nil
  defp array_element({_quoted?, value}, element_type), do: convert_value(element_type, value)

  defp to_wire(%__MODULE__{} = message) do
    %{
      "topic" => message.topic,
      "event" => message.event,
      "payload" => message.payload || %{},
      "ref" => message.ref,
      "join_ref" => message.join_ref
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp encode_binding(binding) do
    %{"event" => binding.event, "schema" => binding.schema}
    |> maybe_put("table", binding.table)
    |> maybe_put("filter", binding.filter)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_event(nil), do: "*"
  defp normalize_event(:*), do: "*"
  defp normalize_event("*"), do: "*"

  defp normalize_event(event) when is_atom(event),
    do: event |> Atom.to_string() |> String.upcase()

  defp normalize_event(event) when is_binary(event), do: String.upcase(event)

  defp option(options, key, default) when is_list(options), do: Keyword.get(options, key, default)

  defp option(options, key, default) when is_map(options) do
    case Map.fetch(options, key) do
      {:ok, value} -> value
      :error -> Map.get(options, Atom.to_string(key), default)
    end
  end

  defp payload(payload) when is_map(payload), do: payload
  defp payload(_), do: %{}

  defp nilable_string(value) when is_binary(value), do: value
  defp nilable_string(value) when is_integer(value), do: Integer.to_string(value)
  defp nilable_string(_), do: nil
end
