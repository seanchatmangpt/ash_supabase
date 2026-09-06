defmodule AshSupabase.Realtime.Socket do
  @moduledoc """
  The websocket transport for one Realtime channel.

  This GenServer owns a `Mint.WebSocket` connection to
  `wss://<project>.supabase.co/realtime/v1/websocket?apikey=...&vsn=1.0.0` and
  does as little thinking as possible: it moves bytes, keeps a list of
  subscribers, and reconnects. Every protocol decision - what to send, what a
  reply means, when a heartbeat is due, when to rejoin - belongs to
  `AshSupabase.Realtime.Channel`, and every frame is built and parsed by
  `AshSupabase.Realtime.Message`. Those two modules are pure and fully tested;
  this one is deliberately thin because it can only be exercised against a
  running server.

  Prefer the `AshSupabase.Realtime` API over starting sockets yourself. One
  socket carries one channel, so a process that subscribes to three topics holds
  three connections; Supabase counts those against the project's concurrent
  connection limit.

  ## Messages sent to subscribers

    * `{:realtime_change, %AshSupabase.Realtime.Change{}}` for every matching
      change.
    * `{:realtime_error, reason}` for protocol and transport failures. The
      socket recovers on its own, so these are informational.

  ## Optional dependency

  Realtime needs `:mint_web_socket`, which `ash_supabase` declares as optional.
  Add it to your `mix.exs` when you use this module:

      {:mint_web_socket, "~> 1.0"}
  """

  # The socket stops normally once its last subscriber is gone, and a
  # transient child is not restarted after a normal exit.
  use GenServer, restart: :transient

  alias AshSupabase.Client
  alias AshSupabase.Config
  alias AshSupabase.Error
  alias AshSupabase.Realtime.Channel
  alias AshSupabase.Realtime.Message

  require Logger

  # The optional dependency is resolved at runtime by `ensure_websocket!/0`.
  @compile {:no_warn_undefined, [Mint.HTTP, Mint.WebSocket]}

  @tick_interval 1_000
  @reconnect_backoff [1_000, 2_000, 5_000, 10_000]

  @doc """
  Starts a socket for a single topic.

  ## Options

    * `:client` - a client module, `AshSupabase.Config`, or keyword list. Required.
    * `:topic` - the channel topic, with or without the `"realtime:"` prefix. Required.
    * `:postgres_changes` - the subscriptions to install. See
      `AshSupabase.Realtime.Channel.new/2`.
    * `:access_token` - user JWT for the subscription. Defaults to the client's
      `:access_token`.
    * `:subscribers` - processes to notify. Defaults to `[]`.
    * `:name` - a `GenServer` name.
    * `:heartbeat_interval`, `:broadcast`, `:presence`, `:private` - forwarded to
      `AshSupabase.Realtime.Channel.new/2`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Rotates the JWT used by the channel, without rejoining."
  @spec set_auth(GenServer.server(), String.t()) :: :ok
  def set_auth(socket, token) when is_binary(token),
    do: GenServer.cast(socket, {:set_auth, token})

  @doc "Adds a process to the subscriber list and monitors it."
  @spec add_subscriber(GenServer.server(), pid()) :: :ok
  def add_subscriber(socket, pid) when is_pid(pid),
    do: GenServer.call(socket, {:add_subscriber, pid})

  @doc """
  Removes a subscriber.

  When the last subscriber goes away the channel leaves and the socket stops.
  """
  @spec remove_subscriber(GenServer.server(), pid()) :: :ok
  def remove_subscriber(socket, pid) when is_pid(pid),
    do: GenServer.call(socket, {:remove_subscriber, pid})

  @doc "Returns the channel state, for introspection and tests."
  @spec channel(GenServer.server()) :: Channel.t()
  def channel(socket), do: GenServer.call(socket, :channel)

  @impl GenServer
  def init(opts) do
    ensure_websocket!()

    case Client.config(Keyword.fetch!(opts, :client)) do
      {:ok, config} -> start_channel(config, opts)
      {:error, error} -> {:stop, error}
    end
  end

  defp start_channel(config, opts) do
    channel =
      Channel.new(
        Keyword.fetch!(opts, :topic),
        opts
        |> Keyword.take([:postgres_changes, :broadcast, :presence, :private, :heartbeat_interval])
        |> Keyword.put(:access_token, opts[:access_token] || config.access_token)
      )

    {:ok, _} = :timer.send_interval(@tick_interval, :tick)

    state = %{
      config: config,
      channel: channel,
      conn: nil,
      websocket: nil,
      request_ref: nil,
      resp_status: nil,
      resp_headers: [],
      status: :disconnected,
      attempts: 0,
      subscribers: monitor_all(Keyword.get(opts, :subscribers, []))
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl GenServer
  def handle_call({:add_subscriber, pid}, _from, state) do
    if Map.has_key?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      {:reply, :ok, put_in(state.subscribers[pid], Process.monitor(pid))}
    end
  end

  def handle_call({:remove_subscriber, pid}, _from, state) do
    {:reply, :ok, drop_subscriber(state, pid)}
  end

  def handle_call(:channel, _from, state), do: {:reply, state.channel, state}

  @impl GenServer
  def handle_cast({:set_auth, token}, state) do
    {channel, effects} = Channel.set_auth(state.channel, token)
    {:noreply, run(%{state | channel: channel}, effects)}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    {channel, effects} = Channel.tick(state.channel, now())
    {:noreply, run(%{state | channel: channel}, effects)}
  end

  def handle_info(:reconnect, state), do: {:noreply, connect(state)}

  # Sent to ourselves once the last subscriber is gone, so that the `phx_leave`
  # queued just before it is written to the socket first.
  def handle_info(:stop_when_idle, %{subscribers: subscribers} = state) when subscribers == %{} do
    {:stop, :normal, state}
  end

  def handle_info(:stop_when_idle, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, drop_subscriber(state, pid)}
  end

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} -> {:noreply, handle_responses(%{state | conn: conn}, responses)}
      {:error, conn, reason, _responses} -> {:noreply, reconnect(%{state | conn: conn}, reason)}
      :unknown -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    close(state)
    :ok
  end

  defp connect(state) do
    uri = URI.parse(Config.realtime_url(state.config))
    {http_scheme, ws_scheme} = schemes(uri.scheme)
    path = "#{uri.path}?#{URI.encode_query(apikey: state.config.api_key, vsn: Message.vsn())}"

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, uri.host, uri.port, protocols: [:http1]),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(ws_scheme, conn, path, [{"x-api-key", state.config.api_key}]) do
      %{
        state
        | conn: conn,
          request_ref: ref,
          status: :connecting,
          resp_status: nil,
          resp_headers: []
      }
    else
      {:error, reason} -> reconnect(state, reason)
      {:error, conn, reason} -> reconnect(%{state | conn: conn}, reason)
    end
  end

  defp schemes("wss"), do: {:https, :wss}
  defp schemes("ws"), do: {:http, :ws}

  defp schemes(scheme) do
    raise Error.Configuration.exception(
            message:
              "the Realtime URL must use the ws:// or wss:// scheme, got: #{inspect(scheme)}. " <>
                "Check the `:url` setting on your client."
          )
  end

  defp handle_responses(state, responses) do
    Enum.reduce(responses, state, &handle_response(&2, &1))
  end

  defp handle_response(state, {:status, _ref, status}), do: %{state | resp_status: status}

  defp handle_response(state, {:headers, _ref, headers}),
    do: %{state | resp_headers: state.resp_headers ++ headers}

  defp handle_response(state, {:done, ref}) do
    case Mint.WebSocket.new(state.conn, ref, state.resp_status, state.resp_headers) do
      {:ok, conn, websocket} ->
        {channel, effects} = state.channel |> Channel.disconnected() |> Channel.join(now())

        run(
          %{
            state
            | conn: conn,
              websocket: websocket,
              status: :open,
              attempts: 0,
              channel: channel
          },
          effects
        )

      {:error, conn, reason} ->
        reconnect(%{state | conn: conn}, {:upgrade_failed, state.resp_status, reason})
    end
  end

  defp handle_response(state, {:data, _ref, data}) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} -> handle_frames(%{state | websocket: websocket}, frames)
      {:error, websocket, reason} -> reconnect(%{state | websocket: websocket}, reason)
    end
  end

  defp handle_response(state, {:error, _ref, reason}), do: reconnect(state, reason)
  defp handle_response(state, _response), do: state

  defp handle_frames(state, frames), do: Enum.reduce(frames, state, &handle_frame(&2, &1))

  defp handle_frame(state, {:text, text}) do
    {channel, effects} = Channel.handle_message(state.channel, text, now())
    run(%{state | channel: channel}, effects)
  end

  defp handle_frame(state, {:ping, data}), do: send_frame(state, {:pong, data})
  defp handle_frame(state, {:close, code, reason}), do: reconnect(state, {:closed, code, reason})
  defp handle_frame(state, _frame), do: state

  defp run(state, effects), do: Enum.reduce(effects, state, &apply_effect(&2, &1))

  defp apply_effect(state, {:send, message}) do
    case Message.encode(message) do
      {:ok, json} -> send_frame(state, {:text, json})
      {:error, reason} -> notify(state, {:realtime_error, reason})
    end
  end

  defp apply_effect(state, {:notify, change}), do: notify(state, {:realtime_change, change})

  # A stale connection cannot be repaired by rejoining, so the heartbeat timeout
  # is the one error that forces the transport itself to start over.
  defp apply_effect(state, {:error, :heartbeat_timeout}) do
    state |> notify({:realtime_error, :heartbeat_timeout}) |> reconnect(:heartbeat_timeout)
  end

  defp apply_effect(state, {:error, reason}) do
    Logger.warning("[ash_supabase] realtime #{state.channel.topic}: #{inspect(reason)}")
    notify(state, {:realtime_error, reason})
  end

  defp send_frame(%{websocket: nil} = state, _frame), do: state

  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
      %{state | websocket: websocket, conn: conn}
    else
      {:error, %Mint.WebSocket{} = websocket, reason} ->
        reconnect(%{state | websocket: websocket}, reason)

      {:error, conn, reason} ->
        reconnect(%{state | conn: conn}, reason)
    end
  end

  defp notify(state, message) do
    Enum.each(Map.keys(state.subscribers), &send(&1, message))
    state
  end

  defp reconnect(state, reason) do
    Logger.warning(
      "[ash_supabase] realtime #{state.channel.topic} disconnected: #{inspect(reason)}"
    )

    state = close(state)
    delay = Enum.at(@reconnect_backoff, state.attempts, List.last(@reconnect_backoff))
    Process.send_after(self(), :reconnect, delay)

    %{
      state
      | conn: nil,
        websocket: nil,
        request_ref: nil,
        status: :disconnected,
        attempts: state.attempts + 1,
        channel: Channel.disconnected(state.channel)
    }
  end

  defp close(%{conn: nil} = state), do: state

  defp close(state) do
    _ = Mint.HTTP.close(state.conn)
    state
  end

  defp drop_subscriber(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _subscribers} ->
        state

      {monitor_ref, subscribers} ->
        Process.demonitor(monitor_ref, [:flush])
        state = %{state | subscribers: subscribers}

        if subscribers == %{} do
          {channel, effects} = Channel.leave(state.channel)
          state = run(%{state | channel: channel}, effects)
          send(self(), :stop_when_idle)
          state
        else
          state
        end
    end
  end

  defp monitor_all(pids) do
    Map.new(List.wrap(pids), fn pid -> {pid, Process.monitor(pid)} end)
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp ensure_websocket! do
    if Code.ensure_loaded?(Mint.WebSocket) do
      :ok
    else
      raise Error.Configuration.exception(
              message: """
              AshSupabase.Realtime needs the optional `:mint_web_socket` dependency, \
              which is not available.

              Add it to the deps in your mix.exs:

                  {:mint_web_socket, "~> 1.0"}

              then run `mix deps.get`.\
              """
            )
    end
  end
end
