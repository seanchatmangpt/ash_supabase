defmodule AshSupabase.Realtime.Channel do
  @moduledoc """
  The Supabase Realtime channel protocol, as a pure state machine.

  Everything that can go wrong with a Realtime subscription is a protocol
  decision: which `ref` a reply belongs to, whether the server's binding ids
  line up with the filters we asked for, when a heartbeat is overdue, how long
  to wait before rejoining. None of that needs a socket, so none of it lives in
  one. This module owns all of it and returns *effects* for a transport to
  carry out:

    * `{:send, message}` - write this `t:AshSupabase.Realtime.Message.t/0` to the
      websocket.
    * `{:notify, change}` - hand this `t:AshSupabase.Realtime.Change.t/0` to the
      subscribers.
    * `{:error, reason}` - something went wrong; the channel has already moved
      itself to `:errored` and scheduled a rejoin where that makes sense.

  `AshSupabase.Realtime.Socket` is the transport that runs these effects. Tests
  run them by hand, which is why this module is exhaustively covered without a
  server.

  ## Time

  `join/2`, `handle_message/3` and `tick/2` take `now`, a monotonic time in
  milliseconds, rather than reading the clock. Pass
  `System.monotonic_time(:millisecond)` from a process; pass small integers from
  a test. Nothing here starts a timer - `tick/2` is called by the transport
  (once a second is plenty) and decides whether a heartbeat is due, whether the
  last one went unanswered, and whether it is time to rejoin.

  ## Lifecycle

      closed --join--> joining --phx_reply ok--> joined
                          |                        |
                          | phx_reply error        | phx_error / phx_close / heartbeat timeout
                          v                        v
                        errored <----------------- errored --tick after backoff--> joining
                          |
                        leave --> leaving --phx_reply--> closed

  ## Example

      iex> alias AshSupabase.Realtime.{Channel, Message}
      iex> channel = Channel.new("room-1", postgres_changes: [[event: :insert, table: "messages"]])
      iex> {channel, [{:send, join}]} = Channel.join(channel, 0)
      iex> {join.topic, join.event, join.ref, channel.state}
      {"realtime:room-1", "phx_join", "1", :joining}
      iex> reply = %Message{topic: "realtime:room-1", event: "phx_reply", ref: "1",
      ...>   payload: %{"status" => "ok", "response" => %{"postgres_changes" =>
      ...>     [%{"id" => 34219287, "event" => "INSERT", "schema" => "public", "table" => "messages"}]}}}
      iex> {channel, []} = Channel.handle_message(channel, reply, 0)
      iex> {channel.state, Channel.binding_ids(channel)}
      {:joined, [34219287]}
  """

  alias AshSupabase.Realtime.Change
  alias AshSupabase.Realtime.Message

  @heartbeat_interval 25_000
  @rejoin_backoff [1_000, 2_000, 5_000, 10_000]

  @typedoc """
  Where the channel is in its lifecycle.

    * `:closed` - not joined, and not trying to be.
    * `:joining` - a `phx_join` is in flight.
    * `:joined` - subscribed; changes are being delivered.
    * `:leaving` - a `phx_leave` is in flight.
    * `:errored` - the join failed or the channel dropped; a rejoin is scheduled.
  """
  @type state :: :closed | :joining | :joined | :leaving | :errored

  @typedoc "An instruction for the transport."
  @type effect :: {:send, Message.t()} | {:notify, Change.t()} | {:error, term()}

  @typedoc """
  A server-confirmed subscription: the filter we asked for plus the `:id` the
  server assigned to it. `postgres_changes` events name the ids they matched.
  """
  @type server_binding :: %{
          id: integer(),
          event: String.t(),
          schema: String.t(),
          table: String.t() | nil,
          filter: String.t() | nil
        }

  @type t :: %__MODULE__{
          topic: String.t(),
          access_token: String.t() | nil,
          join_ref: String.t() | nil,
          pending_ref: String.t() | nil,
          heartbeat_ref: String.t() | nil,
          next_heartbeat_at: integer() | nil,
          rejoin_at: integer() | nil,
          state: state(),
          postgres_changes: [Message.binding()],
          bindings: [server_binding()],
          broadcast: keyword(),
          presence: keyword(),
          private: boolean(),
          heartbeat?: boolean(),
          heartbeat_interval: pos_integer(),
          ref: non_neg_integer(),
          rejoin_attempts: non_neg_integer()
        }

  defstruct [
    :topic,
    :access_token,
    :join_ref,
    :pending_ref,
    :heartbeat_ref,
    :next_heartbeat_at,
    :rejoin_at,
    state: :closed,
    postgres_changes: [],
    bindings: [],
    broadcast: [],
    presence: [],
    private: false,
    heartbeat?: true,
    heartbeat_interval: @heartbeat_interval,
    ref: 0,
    rejoin_attempts: 0
  ]

  @doc """
  Builds a closed channel for `topic`.

  The topic is prefixed with `"realtime:"` unless it already is: Supabase's
  `UserSocket` only routes `realtime:*`, and the sub-topic is an arbitrary name,
  *not* a table reference. Table and filter selection happens through
  `:postgres_changes`.

  ## Options

    * `:postgres_changes` - subscriptions, each a keyword list or map of
      `:event`, `:schema`, `:table`, `:filter`. See
      `AshSupabase.Realtime.Message.normalize_binding/1`.
    * `:access_token` - the user JWT sent with the join and rotated by
      `set_auth/3`.
    * `:broadcast` / `:presence` / `:private` - forwarded into the join config.
    * `:heartbeat` - whether this channel drives the connection keepalive.
      Defaults to `true`.
    * `:heartbeat_interval` - milliseconds between heartbeats. Defaults to
      `25_000`, the interval the official clients use.

      iex> AshSupabase.Realtime.Channel.new("room-1").topic
      "realtime:room-1"

      iex> AshSupabase.Realtime.Channel.new("realtime:room-1").topic
      "realtime:room-1"
  """
  @spec new(String.t(), keyword()) :: t()
  def new(topic, opts \\ []) when is_binary(topic) do
    %__MODULE__{
      topic: normalize_topic(topic),
      postgres_changes:
        opts |> Keyword.get(:postgres_changes, []) |> Enum.map(&Message.normalize_binding/1),
      access_token: Keyword.get(opts, :access_token),
      broadcast: Keyword.get(opts, :broadcast, []),
      presence: Keyword.get(opts, :presence, []),
      private: Keyword.get(opts, :private, false),
      heartbeat?: Keyword.get(opts, :heartbeat, true),
      heartbeat_interval: Keyword.get(opts, :heartbeat_interval, @heartbeat_interval)
    }
  end

  @doc """
  Prefixes a topic with `"realtime:"` unless it already carries the prefix.

      iex> AshSupabase.Realtime.Channel.normalize_topic("room-1")
      "realtime:room-1"

      iex> AshSupabase.Realtime.Channel.normalize_topic("realtime:room-1")
      "realtime:room-1"
  """
  @spec normalize_topic(String.t()) :: String.t()
  def normalize_topic("realtime:" <> rest = topic) do
    if rest == "" do
      raise ArgumentError,
            "the Realtime sub-topic must not be empty (the server rejects \"realtime:\")"
    end

    topic
  end

  def normalize_topic(""), do: raise(ArgumentError, "the Realtime topic must not be empty")
  def normalize_topic(topic) when is_binary(topic), do: "realtime:" <> topic

  @doc """
  Starts a join, returning the `phx_join` to send.

  Any previously assigned binding ids are discarded: the server assigns new ones
  on every join. Also arms the heartbeat, since a join is only possible on a
  live connection.
  """
  @spec join(t(), integer()) :: {t(), [effect()]}
  def join(%__MODULE__{} = channel, now \\ 0) do
    {ref, channel} = next_ref(channel)

    message =
      Message.join(channel.topic, ref,
        postgres_changes: channel.postgres_changes,
        access_token: channel.access_token,
        broadcast: channel.broadcast,
        presence: channel.presence,
        private: channel.private
      )

    channel = %{
      channel
      | state: :joining,
        join_ref: ref,
        pending_ref: ref,
        bindings: [],
        rejoin_at: nil,
        heartbeat_ref: nil,
        next_heartbeat_at: now + channel.heartbeat_interval
    }

    {channel, [{:send, message}]}
  end

  @doc """
  Starts a leave, returning the `phx_leave` to send.

  A channel that is not joined or joining has nothing to leave, so this is a
  no-op that simply closes it.
  """
  @spec leave(t()) :: {t(), [effect()]}
  def leave(%__MODULE__{state: state} = channel) when state in [:joining, :joined] do
    {ref, channel} = next_ref(channel)

    {%{channel | state: :leaving, pending_ref: ref, next_heartbeat_at: nil},
     [{:send, Message.leave(channel.topic, ref, channel.join_ref)}]}
  end

  def leave(%__MODULE__{} = channel) do
    {%{channel | state: :closed, pending_ref: nil, next_heartbeat_at: nil}, []}
  end

  @doc """
  Rotates the channel's JWT.

  When the channel is joined this pushes an `access_token` event, which keeps
  the replication subscription in place; a rejoin would tear it down and build
  it again. When it is not joined the token is only remembered, and the next
  join carries it.
  """
  @spec set_auth(t(), String.t() | nil) :: {t(), [effect()]}
  def set_auth(%__MODULE__{state: :joined} = channel, token) when is_binary(token) do
    {ref, channel} = next_ref(channel)

    {%{channel | access_token: token},
     [{:send, Message.access_token(channel.topic, ref, channel.join_ref, token)}]}
  end

  def set_auth(%__MODULE__{} = channel, token), do: {%{channel | access_token: token}, []}

  @doc """
  Resets the channel after the transport dropped.

  The socket calls this before reconnecting: refs and binding ids from the old
  connection are meaningless on the new one. The rejoin counter is kept so that
  a flapping connection still backs off.
  """
  @spec disconnected(t()) :: t()
  def disconnected(%__MODULE__{} = channel) do
    %{
      channel
      | state: :closed,
        join_ref: nil,
        pending_ref: nil,
        bindings: [],
        heartbeat_ref: nil,
        next_heartbeat_at: nil,
        rejoin_at: nil
    }
  end

  @doc "The binding ids the server assigned to this channel's filters."
  @spec binding_ids(t()) :: [integer()]
  def binding_ids(%__MODULE__{bindings: bindings}), do: Enum.map(bindings, & &1.id)

  @doc """
  Advances the timers.

  Emits the heartbeat when one is due, fails the channel with
  `{:error, :heartbeat_timeout}` when the previous heartbeat was never answered
  by the time the next one falls due (the connection is stale, and the transport
  should reconnect rather than rejoin), and re-sends the join once the rejoin
  backoff has elapsed.

      iex> alias AshSupabase.Realtime.Channel
      iex> channel = Channel.new("room-1")
      iex> {channel, _} = Channel.join(channel, 0)
      iex> {_channel, [{:send, heartbeat}]} = Channel.tick(channel, 25_000)
      iex> {heartbeat.topic, heartbeat.event}
      {"phoenix", "heartbeat"}
  """
  @spec tick(t(), integer()) :: {t(), [effect()]}
  def tick(%__MODULE__{} = channel, now) do
    {channel, heartbeat_effects} = tick_heartbeat(channel, now)
    {channel, rejoin_effects} = tick_rejoin(channel, now)
    {channel, heartbeat_effects ++ rejoin_effects}
  end

  defp tick_heartbeat(%__MODULE__{heartbeat?: false} = channel, _now), do: {channel, []}
  defp tick_heartbeat(%__MODULE__{next_heartbeat_at: nil} = channel, _now), do: {channel, []}

  defp tick_heartbeat(%__MODULE__{next_heartbeat_at: due} = channel, now) when now < due do
    {channel, []}
  end

  defp tick_heartbeat(%__MODULE__{heartbeat_ref: nil} = channel, now) do
    {ref, channel} = next_ref(channel)

    {%{channel | heartbeat_ref: ref, next_heartbeat_at: now + channel.heartbeat_interval},
     [{:send, Message.heartbeat(ref)}]}
  end

  # A heartbeat is still unanswered a whole interval later: the connection is
  # gone even though the socket has not noticed yet.
  defp tick_heartbeat(%__MODULE__{} = channel, now) do
    {error(channel, now, heartbeat_ref: nil, next_heartbeat_at: nil),
     [{:error, :heartbeat_timeout}]}
  end

  defp tick_rejoin(%__MODULE__{state: :errored, rejoin_at: rejoin_at} = channel, now)
       when is_integer(rejoin_at) and rejoin_at <= now do
    join(%{channel | rejoin_attempts: channel.rejoin_attempts + 1}, now)
  end

  defp tick_rejoin(%__MODULE__{} = channel, _now), do: {channel, []}

  @doc """
  Feeds one server message through the state machine.

  Accepts a decoded `t:AshSupabase.Realtime.Message.t/0` or a raw JSON frame; a
  frame that cannot be decoded produces an `{:error, reason}` effect instead of
  raising, because a malformed frame must not take the socket down.

  Messages for another topic are ignored, so a socket may feed every frame it
  receives to every channel it owns.
  """
  @spec handle_message(t(), Message.t() | binary() | map(), integer()) :: {t(), [effect()]}
  def handle_message(channel, message, now \\ 0)

  def handle_message(%__MODULE__{} = channel, %Message{} = message, now) do
    dispatch(channel, message, now)
  end

  def handle_message(%__MODULE__{} = channel, frame, now) do
    case Message.decode(frame) do
      {:ok, message} -> dispatch(channel, message, now)
      {:error, reason} -> {channel, [{:error, reason}]}
    end
  end

  # The heartbeat rides the connection-level "phoenix" topic, so its reply is
  # the one server message that does not carry our channel topic.
  defp dispatch(
         %__MODULE__{} = channel,
         %Message{topic: "phoenix", event: "phx_reply", ref: ref},
         _now
       )
       when is_binary(ref) do
    if ref == channel.heartbeat_ref do
      {%{channel | heartbeat_ref: nil}, []}
    else
      {channel, []}
    end
  end

  defp dispatch(%__MODULE__{} = channel, %Message{topic: "phoenix"}, _now), do: {channel, []}

  defp dispatch(%__MODULE__{topic: topic} = channel, %Message{topic: other}, _now)
       when topic != other do
    {channel, []}
  end

  defp dispatch(
         %__MODULE__{state: :joining, pending_ref: ref} = channel,
         %Message{event: "phx_reply", ref: ref} = message,
         now
       )
       when is_binary(ref) do
    join_reply(channel, message.payload, now)
  end

  defp dispatch(
         %__MODULE__{state: :leaving, pending_ref: ref} = channel,
         %Message{event: "phx_reply", ref: ref},
         _now
       )
       when is_binary(ref) do
    {%{
       channel
       | state: :closed,
         pending_ref: nil,
         join_ref: nil,
         bindings: [],
         next_heartbeat_at: nil
     }, []}
  end

  defp dispatch(%__MODULE__{} = channel, %Message{event: "phx_reply"}, _now), do: {channel, []}

  defp dispatch(%__MODULE__{} = channel, %Message{event: "postgres_changes"} = message, _now) do
    change(channel, message)
  end

  defp dispatch(%__MODULE__{} = channel, %Message{event: event} = message, _now)
       when event in ["INSERT", "UPDATE", "DELETE"] do
    change(channel, message)
  end

  defp dispatch(%__MODULE__{} = channel, %Message{event: "system", payload: payload}, now) do
    case payload do
      %{"status" => "error"} -> {error(channel, now), [{:error, {:system_error, payload}}]}
      _ -> {channel, []}
    end
  end

  defp dispatch(%__MODULE__{} = channel, %Message{event: "phx_error", payload: payload}, now) do
    {error(channel, now), [{:error, {:channel_error, payload}}]}
  end

  # A close we asked for is not a failure; one we did not is a dropped channel.
  defp dispatch(%__MODULE__{state: state} = channel, %Message{event: "phx_close"}, _now)
       when state in [:leaving, :closed] do
    {%{
       channel
       | state: :closed,
         pending_ref: nil,
         join_ref: nil,
         bindings: [],
         next_heartbeat_at: nil
     }, []}
  end

  defp dispatch(%__MODULE__{} = channel, %Message{event: "phx_close", payload: payload}, now) do
    {error(channel, now), [{:error, {:channel_closed, payload}}]}
  end

  defp dispatch(%__MODULE__{} = channel, %Message{}, _now), do: {channel, []}

  defp join_reply(channel, %{"status" => "ok"} = payload, now) do
    server_bindings = get_in(payload, ["response", "postgres_changes"]) || []

    case match_bindings(channel.postgres_changes, server_bindings) do
      {:ok, bindings} ->
        {%{
           channel
           | state: :joined,
             pending_ref: nil,
             bindings: bindings,
             rejoin_attempts: 0,
             rejoin_at: nil
         }, []}

      {:error, reason} ->
        {error(channel, now), [{:error, reason}]}
    end
  end

  defp join_reply(channel, %{"status" => "error"} = payload, now) do
    {error(channel, now), [{:error, {:join_error, Map.get(payload, "response", payload)}}]}
  end

  defp join_reply(channel, payload, now) do
    {error(channel, now), [{:error, {:join_error, payload}}]}
  end

  # The server echoes the filters back in the order they were requested. A
  # mismatch means the two sides disagree about what is subscribed, and events
  # would be attributed to the wrong filter, so the channel fails instead.
  defp match_bindings(requested, server_bindings) do
    requested
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {binding, index}, {:ok, acc} ->
      match_binding(binding, Enum.at(server_bindings, index), acc)
    end)
    |> case do
      {:ok, bindings} -> {:ok, Enum.reverse(bindings)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp match_binding(binding, %{"id" => id} = server_binding, acc) do
    if same_binding?(binding, server_binding) do
      {:cont, {:ok, [Map.put(binding, :id, id) | acc]}}
    else
      {:halt, {:error, {:binding_mismatch, binding, server_binding}}}
    end
  end

  defp match_binding(binding, other, _acc),
    do: {:halt, {:error, {:binding_mismatch, binding, other}}}

  defp same_binding?(binding, server_binding) do
    binding.event == server_binding["event"] and binding.schema == server_binding["schema"] and
      binding.table == server_binding["table"] and binding.filter == server_binding["filter"]
  end

  defp change(channel, message) do
    case Message.postgres_changes(message) do
      {:ok, change} ->
        if change_for_us?(channel, change) do
          {channel, [{:notify, change}]}
        else
          {channel, []}
        end

      {:error, reason} ->
        {channel, [{:error, reason}]}
    end
  end

  # Legacy-form events carry no ids, and a channel with no confirmed bindings
  # has nothing to match against; in both cases the topic is the only filter.
  defp change_for_us?(_channel, %Change{ids: []}), do: true
  defp change_for_us?(%__MODULE__{bindings: []}, _change), do: true

  defp change_for_us?(channel, %Change{ids: ids}) do
    our_ids = binding_ids(channel)
    Enum.any?(ids, &(&1 in our_ids))
  end

  defp error(channel, now, extra \\ []) do
    channel = struct!(channel, extra)

    %{
      channel
      | state: :errored,
        pending_ref: nil,
        bindings: [],
        rejoin_at: now + rejoin_backoff(channel.rejoin_attempts)
    }
  end

  defp rejoin_backoff(attempts) do
    Enum.at(@rejoin_backoff, attempts, List.last(@rejoin_backoff))
  end

  defp next_ref(%__MODULE__{ref: ref} = channel) do
    {Integer.to_string(ref + 1), %{channel | ref: ref + 1}}
  end
end
