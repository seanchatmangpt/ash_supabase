defmodule AshSupabase.Realtime do
  @moduledoc """
  Subscribe to Postgres changes streamed by Supabase Realtime.

  Realtime is a Phoenix endpoint that tails the database's logical replication
  stream and pushes the rows a client is allowed to see over a websocket. This
  module is the process-level API for it: start it in a supervision tree, then
  `subscribe/3` from any process to receive
  `{:realtime_change, %AshSupabase.Realtime.Change{}}` messages.

      children = [
        {AshSupabase.Realtime, client: MyApp.Supabase, name: MyApp.Realtime}
      ]

      {:ok, _socket} =
        AshSupabase.Realtime.subscribe(MyApp.Realtime, "room-1",
          postgres_changes: [
            [event: :insert, schema: "public", table: "messages", filter: "room_id=eq.1"]
          ]
        )

      receive do
        {:realtime_change, %AshSupabase.Realtime.Change{type: :insert, record: record}} ->
          IO.inspect(record)
      end

  The topic (`"room-1"` above) is an arbitrary channel name, *not* a table
  reference. Tables and filters are declared in `:postgres_changes` and are sent
  in the join payload; the server assigns each one an id and tags every change
  with the ids it matched.

  ## Enabling changes in the database

  A table only reaches the replication stream once it is added to the
  publication, and Row Level Security still applies to the subscribing user:

      alter publication supabase_realtime add table messages;

  ## Messages

    * `{:realtime_change, %AshSupabase.Realtime.Change{}}` - a change matched one
      of the subscription's filters.
    * `{:realtime_error, reason}` - a protocol or transport failure. The socket
      reconnects and rejoins on its own; these are for visibility.

  Subscribers are monitored. When the last subscriber of a topic exits or calls
  `unsubscribe/2`, the channel leaves and its connection is closed.

  ## Authentication

  The join carries the client's `:access_token` (the anon key by default) so
  that RLS evaluates against it. Realtime rejects tokens without `role` and
  `exp` claims. When a user's JWT is refreshed, call `set_auth/2`: it pushes an
  `access_token` message to every open channel, which rotates the credential
  *without* tearing down and re-creating the replication subscription.

  ## What is tested, and what needs a server

  The protocol lives in two pure modules that are exhaustively unit tested with
  no network at all:

    * `AshSupabase.Realtime.Message` - the Phoenix Channels v1.0.0 envelope,
      the join/leave/heartbeat/access_token frames, and decoding
      `postgres_changes` into a `AshSupabase.Realtime.Change`.
    * `AshSupabase.Realtime.Channel` - the state machine: join, binding-id
      reconciliation from `phx_reply`, heartbeat timing, rejoin backoff, and
      token rotation. It returns effects rather than performing them.

  `AshSupabase.Realtime.Socket` and this module are the thin part: a
  `Mint.WebSocket` connection, a subscriber list, and a reconnect timer. They
  have no unit tests because they only do anything against a live server. To
  exercise them, run Supabase locally:

      supabase start
      # then, with the printed API URL and anon key:
      iex -S mix

      {:ok, _} = AshSupabase.Realtime.start_link(
        client: [url: "http://127.0.0.1:54321", api_key: "<anon key>"],
        name: MyApp.Realtime
      )

      AshSupabase.Realtime.subscribe(MyApp.Realtime, "test",
        postgres_changes: [[event: "*", table: "messages"]])

  Insert a row with `supabase db` or the SQL editor and the `iex` process
  receives a `{:realtime_change, ...}` message. `flush()` shows it.

  ## Optional dependency

  Realtime needs `:mint_web_socket`, which `ash_supabase` declares as optional.
  Starting a socket without it raises `AshSupabase.Error.Configuration` naming
  the line to add:

      {:mint_web_socket, "~> 1.0"}
  """

  use Supervisor

  alias AshSupabase.Realtime.Channel
  alias AshSupabase.Realtime.Socket

  @typedoc "The name (or pid) of a running `AshSupabase.Realtime` supervisor."
  @type t :: Supervisor.supervisor()

  @doc """
  Starts the Realtime supervisor: a `Registry` of topics and a
  `DynamicSupervisor` of sockets.

  ## Options

    * `:client` - a client module, `AshSupabase.Config`, or keyword list of
      settings. Required.
    * `:name` - the supervisor name, also the base for the registry and socket
      supervisor names. Defaults to `AshSupabase.Realtime`.
    * `:access_token` - initial JWT for new subscriptions. Defaults to the
      client's own token.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl Supervisor
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    client = Keyword.fetch!(opts, :client)

    children = [
      {Registry,
       keys: :unique,
       name: registry(name),
       meta: [client: client, access_token: Keyword.get(opts, :access_token)]},
      {DynamicSupervisor, name: sockets(name), strategy: :one_for_one}
    ]

    # The registry holds the settings the socket supervisor's children need, so
    # a registry restart must take the sockets with it.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Subscribes the calling process to `topic` and returns the socket carrying it.

  Topics are shared: subscribing to a topic that is already open adds the
  process to the existing channel's subscribers rather than opening a second
  connection, and the `:postgres_changes` of the first subscription stay in
  force. Use distinct topic names for distinct filters.

  ## Options

    * `:postgres_changes` - the subscriptions, each a keyword list or map of
      `:event` (`:insert`, `:update`, `:delete` or `"*"`), `:schema`, `:table`
      and `:filter` (a PostgREST filter such as `"room_id=eq.1"`).
    * `:subscriber` - the process to notify. Defaults to the caller.
    * `:access_token` - JWT for this channel, overriding the supervisor's.
    * `:broadcast`, `:presence`, `:private`, `:heartbeat_interval` - forwarded to
      `AshSupabase.Realtime.Channel.new/2`.
  """
  @spec subscribe(t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def subscribe(realtime \\ __MODULE__, topic, opts \\ []) when is_binary(topic) do
    registry = registry(realtime)
    subscriber = Keyword.get(opts, :subscriber, self())

    with {:ok, client} <- meta(registry, :client) do
      socket_opts =
        opts
        |> Keyword.drop([:subscriber])
        |> Keyword.put_new_lazy(:access_token, fn -> registry |> meta(:access_token) |> ok() end)
        |> Keyword.merge(
          client: client,
          topic: topic,
          subscribers: [subscriber],
          name: {:via, Registry, {registry, Channel.normalize_topic(topic)}}
        )

      case DynamicSupervisor.start_child(sockets(realtime), {Socket, socket_opts}) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          :ok = Socket.add_subscriber(pid, subscriber)
          {:ok, pid}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Removes the calling process from `topic`.

  Returns `:ok` whether or not there was a subscription. When no subscribers are
  left the channel sends `phx_leave` and the socket shuts down.
  """
  @spec unsubscribe(t(), String.t()) :: :ok
  def unsubscribe(realtime \\ __MODULE__, topic) when is_binary(topic) do
    case Registry.lookup(registry(realtime), Channel.normalize_topic(topic)) do
      [{pid, _value}] -> Socket.remove_subscriber(pid, self())
      [] -> :ok
    end
  end

  @doc """
  Rotates the JWT used by every open channel, and by channels opened later.

  Call this after refreshing a user's session. Channels push an `access_token`
  message instead of rejoining, so no changes are missed while the credential
  is swapped.
  """
  @spec set_auth(t(), String.t()) :: :ok
  def set_auth(realtime \\ __MODULE__, token) when is_binary(token) do
    :ok = Registry.put_meta(registry(realtime), :access_token, token)

    realtime
    |> sockets()
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_id, pid, :worker, _modules} when is_pid(pid) -> Socket.set_auth(pid, token)
      _child -> :ok
    end)
  end

  @doc """
  Lists the topics with an open socket, and the pid carrying each.

      AshSupabase.Realtime.subscriptions(MyApp.Realtime)
      #=> [{"realtime:room-1", #PID<0.321.0>}]
  """
  @spec subscriptions(t()) :: [{String.t(), pid()}]
  def subscriptions(realtime \\ __MODULE__) do
    Registry.select(registry(realtime), [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc "The registry name used by a Realtime instance."
  @spec registry(t()) :: atom()
  def registry(realtime) when is_atom(realtime), do: Module.concat(realtime, Registry)

  @doc "The dynamic supervisor name used by a Realtime instance."
  @spec sockets(t()) :: atom()
  def sockets(realtime) when is_atom(realtime), do: Module.concat(realtime, Sockets)

  defp meta(registry, key) do
    case Registry.meta(registry, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        {:error,
         "#{inspect(registry)} is not running. Did you add AshSupabase.Realtime to your supervision tree?"}
    end
  end

  defp ok({:ok, value}), do: value
  defp ok(_), do: nil
end
