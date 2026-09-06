defmodule AshSupabase.Realtime.MessageTest do
  use ExUnit.Case, async: true

  alias AshSupabase.Realtime.Change
  alias AshSupabase.Realtime.Message

  doctest AshSupabase.Realtime.Message

  # The frames below are the ones documented for a Supabase Realtime session:
  # join, the reply carrying server-assigned ids, the system ack, and the three
  # change events.
  @join_reply ~s({"topic":"realtime:room-1","event":"phx_reply","ref":"1","payload":{"status":"ok","response":{"postgres_changes":[{"id":34219287,"event":"*","schema":"public","table":"messages","filter":"room_id=eq.1"}]}}})

  @system ~s({"topic":"realtime:room-1","event":"system","ref":null,"payload":{"extension":"postgres_changes","status":"ok","message":"Subscribed to PostgreSQL","channel":"room-1"}})

  @insert ~s({"topic":"realtime:room-1","event":"postgres_changes","ref":null,"payload":{"ids":[34219287],"data":{"schema":"public","table":"messages","commit_timestamp":"2026-09-06T12:00:00.000Z","type":"INSERT","columns":[{"name":"id","type":"int8"},{"name":"body","type":"text"},{"name":"room_id","type":"int8"}],"record":{"id":7,"body":"hi","room_id":1},"errors":null}}})

  @update ~s({"topic":"realtime:room-1","event":"postgres_changes","ref":null,"payload":{"ids":[34219287],"data":{"schema":"public","table":"messages","commit_timestamp":"2026-09-06T12:00:01.000Z","type":"UPDATE","columns":[{"name":"id","type":"int8"},{"name":"body","type":"text"}],"record":{"id":7,"body":"edited"},"old_record":{"id":7},"errors":null}}})

  @delete ~s({"topic":"realtime:room-1","event":"postgres_changes","ref":null,"payload":{"ids":[34219287],"data":{"schema":"public","table":"messages","commit_timestamp":"2026-09-06T12:00:02.000Z","type":"DELETE","columns":[{"name":"id","type":"int8"}],"old_record":{"id":7},"errors":null}}})

  describe "vsn/0" do
    test "is the object serializer version Realtime requires" do
      assert Message.vsn() == "1.0.0"
    end
  end

  describe "encode/1" do
    test "writes the five-key object envelope" do
      message = %Message{
        topic: "realtime:room-1",
        event: "phx_join",
        ref: "1",
        join_ref: "1",
        payload: %{"config" => %{}}
      }

      assert {:ok, json} = Message.encode(message)

      assert Jason.decode!(json) == %{
               "topic" => "realtime:room-1",
               "event" => "phx_join",
               "ref" => "1",
               "join_ref" => "1",
               "payload" => %{"config" => %{}}
             }
    end

    test "omits nil refs so a heartbeat matches the frame the official clients send" do
      assert {:ok, json} = Message.encode(Message.heartbeat("2"))

      assert Jason.decode!(json) == %{
               "topic" => "phoenix",
               "event" => "heartbeat",
               "ref" => "2",
               "payload" => %{}
             }
    end

    test "encodes a nil payload as an empty object" do
      assert {:ok, json} = Message.encode(%Message{topic: "t", event: "e", payload: nil})
      assert Jason.decode!(json)["payload"] == %{}
    end

    test "reports terms that cannot be encoded" do
      message = %Message{topic: "t", event: "e", payload: %{"pid" => self()}}
      assert {:error, {:encode_error, _}} = Message.encode(message)
    end

    test "encode!/1 raises on an unencodable payload" do
      message = %Message{topic: "t", event: "e", payload: %{"pid" => self()}}
      assert_raise Protocol.UndefinedError, fn -> Message.encode!(message) end
    end

    test "encode!/1 returns the JSON on success" do
      assert Message.heartbeat("9") |> Message.encode!() |> Jason.decode!() |> Map.fetch!("ref") ==
               "9"
    end
  end

  describe "decode/1" do
    test "decodes a phx_reply" do
      assert {:ok, message} = Message.decode(@join_reply)
      assert message.topic == "realtime:room-1"
      assert message.event == "phx_reply"
      assert message.ref == "1"
      assert message.join_ref == nil
      assert message.payload["status"] == "ok"

      assert [%{"id" => 34_219_287, "event" => "*"}] =
               message.payload["response"]["postgres_changes"]
    end

    test "decodes a server message with a null ref" do
      assert {:ok, message} = Message.decode(@system)
      assert message.ref == nil
      assert message.payload["extension"] == "postgres_changes"
    end

    test "tolerates a missing payload" do
      assert {:ok, %Message{payload: %{}}} = Message.decode(~s({"topic":"t","event":"e"}))
    end

    test "stringifies an integer ref" do
      assert {:ok, %Message{ref: "12"}} = Message.decode(~s({"topic":"t","event":"e","ref":12}))
    end

    test "passes an already decoded message through" do
      message = Message.heartbeat("1")
      assert Message.decode(message) == {:ok, message}
    end

    test "decodes an already parsed JSON object" do
      assert {:ok, %Message{topic: "t", event: "e"}} =
               Message.decode(%{"topic" => "t", "event" => "e"})
    end

    test "rejects the Phoenix v2 array frame with an actionable message" do
      assert {:error, {:invalid_frame, message}} =
               Message.decode(~s(["1","1","topic","event",{}]))

      assert message =~ "vsn=1.0.0"
      assert message =~ "array frame"
    end

    test "rejects an object without topic and event" do
      assert {:error, {:invalid_frame, message}} = Message.decode(~s({"payload":{}}))
      assert message =~ "missing"
    end

    test "rejects a non-object JSON document" do
      assert {:error, {:invalid_frame, _}} = Message.decode(~s("just a string"))
    end

    test "reports malformed JSON" do
      assert {:error, {:invalid_json, %Jason.DecodeError{}}} = Message.decode("{not json")
    end

    test "rejects a term that is neither a frame nor a map" do
      assert {:error, {:invalid_frame, _}} = Message.decode(:nope)
    end
  end

  describe "join/3" do
    test "builds the documented join payload" do
      message =
        Message.join("realtime:room-1", "1",
          postgres_changes: [
            [event: "*", schema: "public", table: "messages", filter: "room_id=eq.1"]
          ],
          access_token: "user-jwt"
        )

      assert message.event == "phx_join"
      assert message.ref == "1"
      assert message.join_ref == "1"

      assert Jason.decode!(Message.encode!(message)) == %{
               "topic" => "realtime:room-1",
               "event" => "phx_join",
               "ref" => "1",
               "join_ref" => "1",
               "payload" => %{
                 "access_token" => "user-jwt",
                 "config" => %{
                   "broadcast" => %{"ack" => false, "self" => false},
                   "presence" => %{"key" => "", "enabled" => false},
                   "postgres_changes" => [
                     %{
                       "event" => "*",
                       "schema" => "public",
                       "table" => "messages",
                       "filter" => "room_id=eq.1"
                     }
                   ],
                   "private" => false
                 }
               }
             }
    end

    test "omits access_token when there is none" do
      message = Message.join("realtime:room-1", "1")
      refute Map.has_key?(message.payload, "access_token")
      assert message.payload["config"]["postgres_changes"] == []
    end

    test "carries broadcast, presence and private options" do
      message =
        Message.join("realtime:room-1", "1",
          broadcast: [ack: true, self: true],
          presence: [key: "user-1", enabled: true],
          private: true
        )

      config = message.payload["config"]
      assert config["broadcast"] == %{"ack" => true, "self" => true}
      assert config["presence"] == %{"key" => "user-1", "enabled" => true}
      assert config["private"] == true
    end

    test "accepts maps as well as keyword lists for options and bindings" do
      message =
        Message.join("realtime:room-1", "1",
          broadcast: %{ack: true, self: false},
          postgres_changes: [%{"event" => "insert", "table" => "messages"}]
        )

      assert message.payload["config"]["broadcast"]["ack"] == true

      assert message.payload["config"]["postgres_changes"] == [
               %{"event" => "INSERT", "schema" => "public", "table" => "messages"}
             ]
    end

    test "omits table and filter when they are not given" do
      message = Message.join("realtime:room-1", "1", postgres_changes: [[event: :delete]])

      assert message.payload["config"]["postgres_changes"] == [
               %{"event" => "DELETE", "schema" => "public"}
             ]
    end
  end

  describe "leave/3, heartbeat/1 and access_token/4" do
    test "leave carries the join_ref of the channel incarnation" do
      assert %Message{event: "phx_leave", ref: "4", join_ref: "1", payload: %{}} =
               Message.leave("realtime:room-1", "4", "1")
    end

    test "heartbeat rides the connection-level topic" do
      assert %Message{topic: "phoenix", event: "heartbeat", ref: "2", join_ref: nil, payload: %{}} =
               Message.heartbeat("2")
    end

    test "access_token carries the new JWT" do
      assert %Message{event: "access_token", payload: %{"access_token" => "new"}} =
               Message.access_token("realtime:room-1", "3", "1", "new")
    end
  end

  describe "normalize_binding/1" do
    test "defaults event to * and schema to public" do
      assert Message.normalize_binding(table: "messages") ==
               %{event: "*", schema: "public", table: "messages", filter: nil}
    end

    test "upcases atom and string events" do
      assert Message.normalize_binding(event: :update).event == "UPDATE"
      assert Message.normalize_binding(event: "insert").event == "INSERT"
      assert Message.normalize_binding(event: :*).event == "*"
    end

    test "reads string keys" do
      assert Message.normalize_binding(%{"schema" => "app", "filter" => "id=eq.1"}) ==
               %{event: "*", schema: "app", table: nil, filter: "id=eq.1"}
    end
  end

  describe "normalize_columns/1" do
    test "accepts string and atom keys and ignores junk" do
      assert Message.normalize_columns([
               %{"name" => "id", "type" => "int8"},
               %{name: "body", type: "text"},
               "nonsense"
             ]) == [%{name: "id", type: "int8"}, %{name: "body", type: "text"}]
    end

    test "returns an empty list when metadata is missing" do
      assert Message.normalize_columns(nil) == []
    end
  end

  describe "postgres_changes/2" do
    test "normalizes an INSERT" do
      assert {:ok, change} = @insert |> decoded() |> Message.postgres_changes()

      assert %Change{
               type: :insert,
               schema: "public",
               table: "messages",
               commit_timestamp: "2026-09-06T12:00:00.000Z",
               record: %{"id" => 7, "body" => "hi", "room_id" => 1},
               old_record: %{},
               errors: nil,
               ids: [34_219_287],
               topic: "realtime:room-1"
             } = change

      assert change.columns == [
               %{name: "id", type: "int8"},
               %{name: "body", type: "text"},
               %{name: "room_id", type: "int8"}
             ]
    end

    test "normalizes an UPDATE with both records" do
      assert {:ok, change} = @update |> decoded() |> Message.postgres_changes()
      assert change.type == :update
      assert change.record == %{"id" => 7, "body" => "edited"}
      assert change.old_record == %{"id" => 7}
    end

    test "normalizes a DELETE, leaving record empty" do
      assert {:ok, change} = @delete |> decoded() |> Message.postgres_changes()
      assert change.type == :delete
      assert change.record == %{}
      assert change.old_record == %{"id" => 7}
    end

    test "accepts a raw frame" do
      assert {:ok, %Change{type: :insert}} = Message.postgres_changes(@insert)
    end

    test "accepts the payload map and the bare data map" do
      payload = @insert |> Jason.decode!() |> Map.fetch!("payload")

      assert {:ok, %Change{type: :insert, ids: [34_219_287], topic: nil}} =
               Message.postgres_changes(payload)

      assert {:ok, %Change{type: :insert, ids: []}} = Message.postgres_changes(payload["data"])
    end

    test "understands the legacy pre-config wire form" do
      legacy =
        ~s({"topic":"realtime:public:messages","event":"INSERT","ref":null,"payload":{"schema":"public","table":"messages","type":"INSERT","commit_timestamp":"2026-09-06T12:00:00Z","columns":[{"name":"id","type":"int8"}],"record":{"id":"7"},"errors":null}})

      assert {:ok, change} = Message.postgres_changes(legacy)
      assert change.type == :insert
      assert change.ids == []
      assert change.record == %{"id" => 7}
    end

    test "reports an unknown change type" do
      assert {:error, {:unknown_change_type, "TRUNCATE"}} =
               Message.postgres_changes(%{"type" => "TRUNCATE"})
    end

    test "reports a message that is not a change" do
      assert {:ok, message} = Message.decode(@system)
      assert {:error, {:not_a_change, ^message}} = Message.postgres_changes(message)
    end

    test "reports a payload without a data map" do
      assert {:error, {:not_a_change, _}} =
               Message.postgres_changes(%Message{
                 topic: "t",
                 event: "postgres_changes",
                 payload: %{"ids" => [1]}
               })
    end

    test "reports a term that is not a change at all" do
      assert {:error, {:not_a_change, :nope}} = Message.postgres_changes(:nope)
    end

    test "propagates a decode error for a malformed frame" do
      assert {:error, {:invalid_json, _}} = Message.postgres_changes("{oops")
    end

    test "keeps server-reported errors" do
      data = %{"type" => "INSERT", "errors" => ["error record exceeds max_record_bytes"]}
      assert {:ok, change} = Message.postgres_changes(data)
      assert change.errors == ["error record exceeds max_record_bytes"]
    end
  end

  describe "postgres_changes/2 value conversion" do
    test "converts string values using the column types" do
      data = %{
        "type" => "INSERT",
        "columns" => [
          %{"name" => "id", "type" => "int8"},
          %{"name" => "score", "type" => "numeric"},
          %{"name" => "active", "type" => "bool"},
          %{"name" => "meta", "type" => "jsonb"},
          %{"name" => "seen_at", "type" => "timestamp"},
          %{"name" => "tags", "type" => "_text"},
          %{"name" => "body", "type" => "text"}
        ],
        "record" => %{
          "id" => "7",
          "score" => "9.5",
          "active" => "t",
          "meta" => ~s({"a":1}),
          "seen_at" => "2026-09-06 12:00:00",
          "tags" => "{a,b}",
          "body" => "hi"
        }
      }

      assert {:ok, change} = Message.postgres_changes(data)

      assert change.record == %{
               "id" => 7,
               "score" => 9.5,
               "active" => true,
               "meta" => %{"a" => 1},
               "seen_at" => "2026-09-06T12:00:00",
               "tags" => ["a", "b"],
               "body" => "hi"
             }
    end

    test "converts the old_record as well" do
      data = %{
        "type" => "DELETE",
        "columns" => [%{"name" => "id", "type" => "int8"}],
        "old_record" => %{"id" => "7"}
      }

      assert {:ok, %Change{old_record: %{"id" => 7}}} = Message.postgres_changes(data)
    end

    test "keeps raw values with convert: false" do
      data = %{
        "type" => "INSERT",
        "columns" => [%{"name" => "id", "type" => "int8"}],
        "record" => %{"id" => "7"}
      }

      assert {:ok, %Change{record: %{"id" => "7"}}} =
               Message.postgres_changes(data, convert: false)
    end

    test "leaves columns without metadata alone" do
      data = %{"type" => "INSERT", "columns" => [], "record" => %{"id" => "7"}}
      assert {:ok, %Change{record: %{"id" => "7"}}} = Message.postgres_changes(data)
    end
  end

  describe "convert_value/2" do
    test "integers" do
      assert Message.convert_value("int2", "1") == 1
      assert Message.convert_value("int4", "-42") == -42
      assert Message.convert_value("int8", "9007199254740993") == 9_007_199_254_740_993
      assert Message.convert_value("oid", "16385") == 16_385
    end

    test "floats and numerics" do
      assert Message.convert_value("float4", "1.5") == 1.5
      assert Message.convert_value("float8", "-0.25") == -0.25
      assert Message.convert_value("numeric", "10.00") == 10.0
    end

    test "booleans" do
      assert Message.convert_value("bool", "t") == true
      assert Message.convert_value("bool", "true") == true
      assert Message.convert_value("bool", "f") == false
      assert Message.convert_value("bool", "false") == false
    end

    test "json and jsonb" do
      assert Message.convert_value("json", ~s({"a":[1,2]})) == %{"a" => [1, 2]}
      assert Message.convert_value("jsonb", "[1,2]") == [1, 2]
    end

    test "timestamps get the PostgREST-style T separator" do
      assert Message.convert_value("timestamp", "2026-09-06 12:00:00") == "2026-09-06T12:00:00"

      assert Message.convert_value("timestamptz", "2026-09-06 12:00:00+00") ==
               "2026-09-06T12:00:00+00"

      assert Message.convert_value("timestamp", "2026-09-06T12:00:00") == "2026-09-06T12:00:00"
    end

    test "arrays are parsed and their elements converted" do
      assert Message.convert_value("_int4", "{1,2,3}") == [1, 2, 3]
      assert Message.convert_value("_text", "{}") == []
      assert Message.convert_value("_text", ~s({"a,b",c})) == ["a,b", "c"]
      assert Message.convert_value("_text", "{NULL,a}") == [nil, "a"]
      assert Message.convert_value("_text", ~s({"NULL"})) == ["NULL"]
      assert Message.convert_value("_bool", "{t,f}") == [true, false]
      assert Message.convert_value("_text", ~s({"say \\"hi\\""})) == [~s(say "hi")]
    end

    test "a malformed array literal is left alone" do
      assert Message.convert_value("_int4", "{1,2") == "{1,2"
      assert Message.convert_value("_int4", "not an array") == "not an array"
    end

    test "unparseable numbers fall back to the raw string" do
      assert Message.convert_value("int8", "not a number") == "not a number"
      assert Message.convert_value("numeric", "NaN") == "NaN"
    end

    test "undecodable json falls back to the raw string" do
      assert Message.convert_value("json", "{oops") == "{oops"
    end

    test "unknown types, nil and already-typed values pass through" do
      assert Message.convert_value("citext", "hi") == "hi"
      assert Message.convert_value("uuid", "b5d0") == "b5d0"
      assert Message.convert_value(nil, "hi") == "hi"
      assert Message.convert_value("int8", nil) == nil
      assert Message.convert_value("int8", 7) == 7
      assert Message.convert_value("bool", true) == true
      assert Message.convert_value("jsonb", %{"a" => 1}) == %{"a" => 1}
    end
  end

  defp decoded(frame) do
    {:ok, message} = Message.decode(frame)
    message
  end
end
