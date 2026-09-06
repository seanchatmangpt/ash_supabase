defmodule AshSupabase.Realtime.ChannelTest do
  use ExUnit.Case, async: true

  alias AshSupabase.Realtime.Change
  alias AshSupabase.Realtime.Channel
  alias AshSupabase.Realtime.Message

  doctest AshSupabase.Realtime.Channel

  @messages [event: "*", schema: "public", table: "messages", filter: "room_id=eq.1"]

  describe "new/2" do
    test "prefixes the topic" do
      assert Channel.new("room-1").topic == "realtime:room-1"
      assert Channel.new("realtime:room-1").topic == "realtime:room-1"
    end

    test "rejects an empty sub-topic, which the server refuses to route" do
      assert_raise ArgumentError, ~r/must not be empty/, fn -> Channel.new("realtime:") end
      assert_raise ArgumentError, ~r/must not be empty/, fn -> Channel.new("") end
    end

    test "normalizes the requested bindings" do
      channel = Channel.new("room-1", postgres_changes: [[event: :insert, table: "messages"]])

      assert channel.postgres_changes == [
               %{event: "INSERT", schema: "public", table: "messages", filter: nil}
             ]
    end

    test "starts closed with no bindings" do
      channel = Channel.new("room-1")
      assert channel.state == :closed
      assert channel.bindings == []
      assert channel.join_ref == nil
      assert Channel.binding_ids(channel) == []
    end
  end

  describe "join/2" do
    test "emits the join frame and moves to :joining" do
      {channel, effects} =
        "room-1"
        |> Channel.new(postgres_changes: [@messages], access_token: "jwt")
        |> Channel.join(0)

      assert [{:send, %Message{} = message}] = effects
      assert message.topic == "realtime:room-1"
      assert message.event == "phx_join"
      assert message.ref == "1"
      assert message.join_ref == "1"
      assert message.payload["access_token"] == "jwt"

      assert message.payload["config"]["postgres_changes"] == [
               %{
                 "event" => "*",
                 "schema" => "public",
                 "table" => "messages",
                 "filter" => "room_id=eq.1"
               }
             ]

      assert channel.state == :joining
      assert channel.join_ref == "1"
      assert channel.pending_ref == "1"
    end

    test "arms the heartbeat" do
      {channel, _} = Channel.new("room-1") |> Channel.join(1_000)
      assert channel.next_heartbeat_at == 26_000
    end

    test "increments the ref on every push" do
      {channel, [{:send, first}]} = Channel.new("room-1") |> Channel.join(0)
      {_channel, [{:send, second}]} = Channel.join(channel, 0)
      assert first.ref == "1"
      assert second.ref == "2"
    end
  end

  describe "join reply" do
    test "stores the server-assigned binding ids and joins" do
      {channel, _} = joining(postgres_changes: [@messages])

      {channel, effects} =
        Channel.handle_message(
          channel,
          reply_ok(channel, [server_binding(34_219_287, @messages)]),
          0
        )

      assert effects == []
      assert channel.state == :joined
      assert channel.pending_ref == nil
      assert Channel.binding_ids(channel) == [34_219_287]

      assert channel.bindings == [
               %{
                 id: 34_219_287,
                 event: "*",
                 schema: "public",
                 table: "messages",
                 filter: "room_id=eq.1"
               }
             ]
    end

    test "joins a channel with no postgres_changes at all" do
      {channel, _} = joining([])
      {channel, effects} = Channel.handle_message(channel, reply_ok(channel, []), 0)
      assert effects == []
      assert channel.state == :joined
    end

    test "matches several bindings in order" do
      inserts = [event: :insert, table: "messages"]
      deletes = [event: :delete, table: "messages"]
      {channel, _} = joining(postgres_changes: [inserts, deletes])

      reply = reply_ok(channel, [server_binding(1, inserts), server_binding(2, deletes)])
      {channel, []} = Channel.handle_message(channel, reply, 0)

      assert Channel.binding_ids(channel) == [1, 2]
    end

    test "fails when the server echoes a different filter" do
      {channel, _} = joining(postgres_changes: [@messages])

      mismatched =
        reply_ok(channel, [
          server_binding(1, event: "*", table: "messages", filter: "room_id=eq.2")
        ])

      {channel, effects} = Channel.handle_message(channel, mismatched, 10)

      assert [{:error, {:binding_mismatch, requested, returned}}] = effects
      assert requested.filter == "room_id=eq.1"
      assert returned["filter"] == "room_id=eq.2"
      assert channel.state == :errored
      assert channel.bindings == []
    end

    test "fails when the server returns bindings out of order" do
      inserts = [event: :insert, table: "messages"]
      deletes = [event: :delete, table: "messages"]
      {channel, _} = joining(postgres_changes: [inserts, deletes])

      reply = reply_ok(channel, [server_binding(2, deletes), server_binding(1, inserts)])
      {channel, [{:error, {:binding_mismatch, _, _}}]} = Channel.handle_message(channel, reply, 0)

      assert channel.state == :errored
    end

    test "fails when the server returns fewer bindings than requested" do
      {channel, _} = joining(postgres_changes: [@messages])
      {channel, effects} = Channel.handle_message(channel, reply_ok(channel, []), 0)

      assert [{:error, {:binding_mismatch, _requested, nil}}] = effects
      assert channel.state == :errored
    end

    test "reports a rejected join and schedules a rejoin" do
      {channel, _} = joining(postgres_changes: [@messages])

      reply = %Message{
        topic: channel.topic,
        event: "phx_reply",
        ref: channel.pending_ref,
        payload: %{"status" => "error", "response" => %{"reason" => "Unauthorized"}}
      }

      {channel, effects} = Channel.handle_message(channel, reply, 500)

      assert effects == [{:error, {:join_error, %{"reason" => "Unauthorized"}}}]
      assert channel.state == :errored
      assert channel.rejoin_at == 1_500
    end

    test "reports a reply with no recognizable status" do
      {channel, _} = joining([])

      reply = %Message{
        topic: channel.topic,
        event: "phx_reply",
        ref: channel.pending_ref,
        payload: %{"weird" => true}
      }

      {channel, [{:error, {:join_error, %{"weird" => true}}}]} =
        Channel.handle_message(channel, reply, 0)

      assert channel.state == :errored
    end

    test "ignores a reply whose ref is not the one in flight" do
      {channel, _} = joining([])

      stale = %Message{
        topic: channel.topic,
        event: "phx_reply",
        ref: "99",
        payload: %{"status" => "ok"}
      }

      assert {^channel, []} = Channel.handle_message(channel, stale, 0)
      assert channel.state == :joining
    end
  end

  describe "postgres_changes" do
    test "notifies with a normalized change" do
      channel = joined(postgres_changes: [@messages], id: 34_219_287)

      {^channel, [{:notify, %Change{} = change}]} =
        Channel.handle_message(channel, change_frame([34_219_287], "INSERT"), 0)

      assert change.type == :insert
      assert change.table == "messages"
      assert change.record == %{"id" => 7, "body" => "hi"}
      assert change.topic == "realtime:room-1"
    end

    test "ignores a change whose ids belong to another binding" do
      channel = joined(postgres_changes: [@messages], id: 34_219_287)

      assert {^channel, []} = Channel.handle_message(channel, change_frame([999], "INSERT"), 0)
    end

    test "delivers a change that matches any of its ids" do
      channel = joined(postgres_changes: [@messages], id: 7)

      assert {^channel, [{:notify, _}]} =
               Channel.handle_message(channel, change_frame([1, 7], "UPDATE"), 0)
    end

    test "delivers a legacy INSERT event, which carries no ids" do
      channel = joined(postgres_changes: [@messages], id: 34_219_287)

      legacy = %Message{
        topic: channel.topic,
        event: "INSERT",
        payload: %{"type" => "INSERT", "table" => "messages", "record" => %{"id" => 1}}
      }

      assert {^channel, [{:notify, %Change{type: :insert}}]} =
               Channel.handle_message(channel, legacy, 0)
    end

    test "reports a change it cannot decode" do
      channel = joined(postgres_changes: [@messages], id: 1)

      broken = %Message{
        topic: channel.topic,
        event: "postgres_changes",
        payload: %{"ids" => [1], "data" => %{"type" => "TRUNCATE"}}
      }

      assert {^channel, [{:error, {:unknown_change_type, "TRUNCATE"}}]} =
               Channel.handle_message(channel, broken, 0)
    end

    test "accepts a raw JSON frame" do
      channel = joined(postgres_changes: [@messages], id: 34_219_287)
      frame = Message.encode!(change_frame([34_219_287], "DELETE"))

      assert {^channel, [{:notify, %Change{type: :delete}}]} =
               Channel.handle_message(channel, frame, 0)
    end
  end

  describe "system, error and close events" do
    test "ignores a successful system ack" do
      channel = joined(postgres_changes: [@messages], id: 1)

      ack = %Message{
        topic: channel.topic,
        event: "system",
        payload: %{
          "extension" => "postgres_changes",
          "status" => "ok",
          "message" => "Subscribed to PostgreSQL",
          "channel" => "room-1"
        }
      }

      assert {^channel, []} = Channel.handle_message(channel, ack, 0)
    end

    test "fails on a system error" do
      channel = joined(postgres_changes: [@messages], id: 1)

      failure = %Message{
        topic: channel.topic,
        event: "system",
        payload: %{"extension" => "postgres_changes", "status" => "error", "message" => "boom"}
      }

      {channel, [{:error, {:system_error, payload}}]} =
        Channel.handle_message(channel, failure, 0)

      assert payload["message"] == "boom"
      assert channel.state == :errored
    end

    test "fails on phx_error" do
      channel = joined(postgres_changes: [@messages], id: 1)

      {channel, effects} =
        Channel.handle_message(channel, %Message{topic: channel.topic, event: "phx_error"}, 100)

      assert effects == [{:error, {:channel_error, %{}}}]
      assert channel.state == :errored
      assert channel.rejoin_at == 1_100
    end

    test "an unexpected phx_close is a failure" do
      channel = joined(postgres_changes: [@messages], id: 1)

      {channel, [{:error, {:channel_closed, %{}}}]} =
        Channel.handle_message(channel, %Message{topic: channel.topic, event: "phx_close"}, 0)

      assert channel.state == :errored
    end

    test "ignores unknown events" do
      channel = joined(postgres_changes: [@messages], id: 1)
      broadcast = %Message{topic: channel.topic, event: "broadcast", payload: %{"event" => "x"}}

      assert {^channel, []} = Channel.handle_message(channel, broadcast, 0)
    end

    test "ignores messages for another topic" do
      channel = joined(postgres_changes: [@messages], id: 1)
      other = %Message{topic: "realtime:other", event: "phx_error"}

      assert {^channel, []} = Channel.handle_message(channel, other, 0)
    end

    test "reports a malformed frame without changing state" do
      channel = joined(postgres_changes: [@messages], id: 1)

      assert {^channel, [{:error, {:invalid_json, _}}]} =
               Channel.handle_message(channel, "{oops", 0)
    end
  end

  describe "heartbeat" do
    test "is silent before it falls due" do
      {channel, _} = Channel.new("room-1") |> Channel.join(0)
      assert {^channel, []} = Channel.tick(channel, 24_999)
    end

    test "is sent when due and rescheduled" do
      {channel, _} = Channel.new("room-1") |> Channel.join(0)
      {channel, [{:send, heartbeat}]} = Channel.tick(channel, 25_000)

      assert heartbeat.topic == "phoenix"
      assert heartbeat.event == "heartbeat"
      assert heartbeat.payload == %{}
      assert channel.heartbeat_ref == heartbeat.ref
      assert channel.next_heartbeat_at == 50_000
    end

    test "a reply on the phoenix topic clears the pending heartbeat" do
      {channel, _} = Channel.new("room-1") |> Channel.join(0)
      {channel, [{:send, heartbeat}]} = Channel.tick(channel, 25_000)

      reply = %Message{
        topic: "phoenix",
        event: "phx_reply",
        ref: heartbeat.ref,
        payload: %{"status" => "ok", "response" => %{}}
      }

      {channel, []} = Channel.handle_message(channel, reply, 25_100)
      assert channel.heartbeat_ref == nil
    end

    test "a reply for a different heartbeat ref is ignored" do
      {channel, _} = Channel.new("room-1") |> Channel.join(0)
      {channel, [{:send, _}]} = Channel.tick(channel, 25_000)

      stale = %Message{topic: "phoenix", event: "phx_reply", ref: "999", payload: %{}}
      {channel, []} = Channel.handle_message(channel, stale, 0)
      assert channel.heartbeat_ref != nil
    end

    test "other messages on the phoenix topic are ignored" do
      {channel, _} = Channel.new("room-1") |> Channel.join(0)

      assert {^channel, []} =
               Channel.handle_message(channel, %Message{topic: "phoenix", event: "phx_error"}, 0)
    end

    test "an unanswered heartbeat fails the channel" do
      {channel, _} = Channel.new("room-1") |> Channel.join(0)
      {channel, [{:send, _}]} = Channel.tick(channel, 25_000)
      {channel, effects} = Channel.tick(channel, 50_000)

      assert effects == [{:error, :heartbeat_timeout}]
      assert channel.state == :errored
      assert channel.heartbeat_ref == nil
      assert channel.next_heartbeat_at == nil
    end

    test "can be disabled for channels that do not own the connection" do
      {channel, _} = Channel.new("room-1", heartbeat: false) |> Channel.join(0)
      assert {^channel, []} = Channel.tick(channel, 100_000)
    end

    test "honors a custom interval" do
      {channel, _} = Channel.new("room-1", heartbeat_interval: 1_000) |> Channel.join(0)
      assert {_channel, [{:send, %Message{event: "heartbeat"}}]} = Channel.tick(channel, 1_000)
    end

    test "is not sent on a closed channel" do
      channel = Channel.new("room-1")
      assert {^channel, []} = Channel.tick(channel, 1_000_000)
    end
  end

  describe "rejoin" do
    test "waits for the backoff, then re-sends the join" do
      channel = joined(postgres_changes: [@messages], id: 1)
      {channel, [{:error, _}]} = Channel.handle_message(channel, phx_error(channel), 0)

      assert {^channel, []} = Channel.tick(channel, 999)

      {channel, [{:send, %Message{event: "phx_join"} = join}]} = Channel.tick(channel, 1_000)
      assert channel.state == :joining
      assert channel.rejoin_attempts == 1
      assert join.ref == channel.join_ref
      assert join.payload["config"]["postgres_changes"] != []
    end

    test "backs off further on repeated failures" do
      channel = joined(postgres_changes: [@messages], id: 1)

      {channel, _} = Channel.handle_message(channel, phx_error(channel), 0)
      {channel, [{:send, _}]} = Channel.tick(channel, 1_000)
      {channel, _} = Channel.handle_message(channel, phx_error(channel), 1_000)
      assert channel.rejoin_at == 3_000

      {channel, [{:send, _}]} = Channel.tick(channel, 3_000)
      {channel, _} = Channel.handle_message(channel, phx_error(channel), 3_000)
      assert channel.rejoin_at == 8_000

      {channel, [{:send, _}]} = Channel.tick(channel, 8_000)
      {channel, _} = Channel.handle_message(channel, phx_error(channel), 8_000)
      assert channel.rejoin_at == 18_000

      {channel, [{:send, _}]} = Channel.tick(channel, 18_000)
      {channel, _} = Channel.handle_message(channel, phx_error(channel), 18_000)
      assert channel.rejoin_at == 28_000
    end

    test "a successful rejoin resets the backoff" do
      channel = joined(postgres_changes: [@messages], id: 1)
      {channel, _} = Channel.handle_message(channel, phx_error(channel), 0)
      {channel, [{:send, _}]} = Channel.tick(channel, 1_000)

      reply = reply_ok(channel, [server_binding(1, @messages)])
      {channel, []} = Channel.handle_message(channel, reply, 1_100)

      assert channel.state == :joined
      assert channel.rejoin_attempts == 0
      assert channel.rejoin_at == nil
    end

    test "a rejoin also rearms the heartbeat" do
      channel = joined(postgres_changes: [@messages], id: 1)
      {channel, _} = Channel.handle_message(channel, phx_error(channel), 0)
      {channel, [{:send, _}]} = Channel.tick(channel, 1_000)

      assert channel.next_heartbeat_at == 26_000
    end
  end

  describe "set_auth/2" do
    test "pushes access_token on a joined channel" do
      channel = joined(postgres_changes: [@messages], id: 1)
      {channel, [{:send, message}]} = Channel.set_auth(channel, "new-jwt")

      assert message.topic == "realtime:room-1"
      assert message.event == "access_token"
      assert message.join_ref == channel.join_ref
      assert message.payload == %{"access_token" => "new-jwt"}
      assert channel.access_token == "new-jwt"
    end

    test "only remembers the token when the channel is not joined" do
      {channel, effects} = Channel.new("room-1") |> Channel.set_auth("new-jwt")
      assert effects == []
      assert channel.access_token == "new-jwt"

      {_channel, [{:send, join}]} = Channel.join(channel, 0)
      assert join.payload["access_token"] == "new-jwt"
    end

    test "the token survives a rejoin" do
      channel = joined(postgres_changes: [@messages], id: 1)
      {channel, [{:send, _}]} = Channel.set_auth(channel, "new-jwt")
      {channel, _} = Channel.handle_message(channel, phx_error(channel), 0)
      {_channel, [{:send, join}]} = Channel.tick(channel, 1_000)

      assert join.payload["access_token"] == "new-jwt"
    end
  end

  describe "leave/1" do
    test "sends phx_leave and closes on the reply" do
      channel = joined(postgres_changes: [@messages], id: 1)
      {channel, [{:send, leave}]} = Channel.leave(channel)

      assert leave.event == "phx_leave"
      assert leave.join_ref == channel.join_ref
      assert leave.payload == %{}
      assert channel.state == :leaving

      reply = %Message{
        topic: channel.topic,
        event: "phx_reply",
        ref: channel.pending_ref,
        payload: %{"status" => "ok", "response" => %{}}
      }

      {channel, []} = Channel.handle_message(channel, reply, 0)
      assert channel.state == :closed
      assert channel.bindings == []
    end

    test "an expected phx_close does not error" do
      channel = joined(postgres_changes: [@messages], id: 1)
      {channel, [{:send, _}]} = Channel.leave(channel)

      {channel, []} =
        Channel.handle_message(channel, %Message{topic: channel.topic, event: "phx_close"}, 0)

      assert channel.state == :closed
    end

    test "stops the heartbeat" do
      channel = joined(postgres_changes: [@messages], id: 1)
      {channel, [{:send, _}]} = Channel.leave(channel)

      assert {^channel, []} = Channel.tick(channel, 1_000_000)
    end

    test "is a no-op on a channel that is not joined" do
      channel = Channel.new("room-1")
      assert {%Channel{state: :closed}, []} = Channel.leave(channel)
    end
  end

  describe "disconnected/1" do
    test "forgets the refs and ids of the dead connection" do
      channel = joined(postgres_changes: [@messages], id: 1)
      channel = Channel.disconnected(channel)

      assert channel.state == :closed
      assert channel.join_ref == nil
      assert channel.bindings == []
      assert channel.next_heartbeat_at == nil
      assert channel.rejoin_at == nil
      assert channel.postgres_changes != []
    end

    test "keeps the rejoin counter so a flapping connection still backs off" do
      channel = joined(postgres_changes: [@messages], id: 1)
      {channel, _} = Channel.handle_message(channel, phx_error(channel), 0)
      {channel, [{:send, _}]} = Channel.tick(channel, 1_000)

      assert Channel.disconnected(channel).rejoin_attempts == 1
    end

    test "silences the heartbeat until the next join" do
      {channel, _} = Channel.new("room-1") |> Channel.join(0)
      channel = Channel.disconnected(channel)

      assert {^channel, []} = Channel.tick(channel, 1_000_000)
    end
  end

  defp joining(opts) do
    "room-1" |> Channel.new(opts) |> Channel.join(0)
  end

  defp joined(opts) do
    {id, opts} = Keyword.pop!(opts, :id)
    {channel, _} = joining(opts)

    bindings = Enum.map(opts[:postgres_changes] || [], &server_binding(id, &1))
    {channel, []} = Channel.handle_message(channel, reply_ok(channel, bindings), 0)
    channel
  end

  defp reply_ok(channel, server_bindings) do
    %Message{
      topic: channel.topic,
      event: "phx_reply",
      ref: channel.pending_ref,
      payload: %{
        "status" => "ok",
        "response" => %{"postgres_changes" => server_bindings}
      }
    }
  end

  defp server_binding(id, binding) do
    binding = Message.normalize_binding(binding)

    %{
      "id" => id,
      "event" => binding.event,
      "schema" => binding.schema,
      "table" => binding.table,
      "filter" => binding.filter
    }
  end

  defp phx_error(channel), do: %Message{topic: channel.topic, event: "phx_error", payload: %{}}

  defp change_frame(ids, type) do
    data =
      %{
        "schema" => "public",
        "table" => "messages",
        "commit_timestamp" => "2026-09-06T12:00:00.000Z",
        "type" => type,
        "columns" => [%{"name" => "id", "type" => "int8"}, %{"name" => "body", "type" => "text"}],
        "errors" => nil
      }
      |> Map.merge(
        case type do
          "INSERT" ->
            %{"record" => %{"id" => 7, "body" => "hi"}}

          "UPDATE" ->
            %{"record" => %{"id" => 7, "body" => "edited"}, "old_record" => %{"id" => 7}}

          "DELETE" ->
            %{"old_record" => %{"id" => 7}}
        end
      )

    %Message{
      topic: "realtime:room-1",
      event: "postgres_changes",
      payload: %{"ids" => ids, "data" => data}
    }
  end
end
