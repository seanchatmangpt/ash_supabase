defmodule AshSupabase.PostgREST do
  @moduledoc """
  Executes `AshSupabase.PostgREST.Query` structs against the Supabase Data API.

  This is a thin, complete client for the REST surface: it sends the request,
  parses the response, and turns PostgREST's error shape into
  `AshSupabase.Error`. It has no opinion about Ash — `AshSupabase.DataLayer`
  builds on it, and so can you.

      iex> alias AshSupabase.PostgREST
      iex> alias AshSupabase.PostgREST.Query
      iex> query = Query.new("posts") |> Query.add_filters([{"status", "eq.published"}])
      iex> match?({:ok, _rows, _meta}, PostgREST.run(MyApp.Supabase, query))
      true

  ## Destructive requests

  PostgREST scopes `PATCH` and `DELETE` entirely by the query string, so a
  request with no filters rewrites or deletes **every row in the table**. Both
  `update/4` and `delete/3` refuse an unfiltered request unless you pass
  `allow_unfiltered?: true`, which makes "delete everything" something you have
  to ask for rather than something you can reach by accident.
  """

  alias AshSupabase.Client
  alias AshSupabase.Error
  alias AshSupabase.PostgREST.Query

  @typedoc """
  Metadata parsed from the response.

  `:count` is the total row count when the query asked for one (via
  `Query.count/2`), and `nil` otherwise.
  """
  @type meta :: %{count: non_neg_integer() | nil, status: integer()}

  @type result :: {:ok, [map()] | map() | nil, meta()} | {:error, Exception.t()}

  @doc """
  Runs a read query, returning `{:ok, rows, meta}`.

  ## Options

    * `:token` - act as this user's JWT for Row Level Security.
  """
  @spec run(Client.t(), Query.t(), keyword()) :: result()
  def run(client, query, opts \\ [])

  def run(_client, %Query{impossible?: true}, _opts), do: {:ok, [], empty_meta()}

  def run(client, %Query{} = query, opts) do
    request(client, :get, query, opts)
  end

  @doc """
  Inserts one record (a map) or many (a list of maps).

  Set up upserts with `AshSupabase.PostgREST.Query.upsert/3` before calling.
  """
  @spec insert(Client.t(), Query.t(), map() | [map()], keyword()) :: result()
  def insert(client, %Query{} = query, records, opts \\ []) do
    request(client, :post, query, Keyword.put(opts, :json, records))
  end

  @doc """
  Applies `changes` to every row matching the query's filters.

  Refuses an unfiltered update unless `allow_unfiltered?: true` is passed.
  """
  @spec update(Client.t(), Query.t(), map(), keyword()) :: result()
  def update(client, %Query{} = query, changes, opts \\ []) do
    with :ok <- ensure_filtered(query, :update, opts) do
      request(client, :patch, query, Keyword.put(opts, :json, changes))
    end
  end

  @doc """
  Deletes every row matching the query's filters.

  Refuses an unfiltered delete unless `allow_unfiltered?: true` is passed.
  """
  @spec delete(Client.t(), Query.t(), keyword()) :: result()
  def delete(client, %Query{} = query, opts \\ []) do
    with :ok <- ensure_filtered(query, :delete, opts) do
      request(client, :delete, query, opts)
    end
  end

  @doc """
  Calls a Postgres function exposed through `/rest/v1/rpc/<name>`.

  `args` is a flat map keyed by parameter name. Postgres lowercases parameter
  names unless the function was declared with quoted identifiers, so prefer
  lowercase keys.

  ## Options

    * `:method` - `:post` (default) or `:get`. `:get` only works for
      `IMMUTABLE`/`STABLE` functions.
    * `:query` - an `AshSupabase.PostgREST.Query` used to apply `select`,
      filters, ordering and pagination to a set-returning function.
  """
  @spec rpc(Client.t(), String.t() | atom(), map(), keyword()) :: result()
  def rpc(client, function, args \\ %{}, opts \\ []) do
    query = Keyword.get(opts, :query) || Query.new("rpc/#{function}")
    query = %{query | table: "rpc/#{function}"}

    case Keyword.get(opts, :method, :post) do
      :post -> request(client, :post, query, Keyword.put(opts, :json, args))
      :get -> request(client, :get, query, Keyword.update(opts, :params, args, & &1))
    end
  end

  defp request(client, method, %Query{} = query, opts) do
    request_opts =
      [
        params: Query.to_params(query) ++ extra_params(opts),
        headers: Query.to_headers(query),
        token: opts[:token],
        schema: query.schema
      ]
      |> put_if(:json, Keyword.fetch(opts, :json))
      |> Keyword.merge(Keyword.get(opts, :req_options, []) |> then(&[req_options: &1]))

    case Client.request(client, method, Query.path(query), request_opts) do
      {:ok, response} -> {:ok, rows(response), meta(response)}
      {:error, error} -> {:error, error}
    end
  end

  defp extra_params(opts) do
    case Keyword.get(opts, :params) do
      nil ->
        []

      params when is_map(params) ->
        Enum.map(params, fn {k, v} -> {to_string(k), to_string(v)} end)

      params when is_list(params) ->
        params
    end
  end

  defp put_if(opts, _key, :error), do: opts
  defp put_if(opts, key, {:ok, value}), do: Keyword.put(opts, key, value)

  defp rows(%{body: nil}), do: []
  defp rows(%{body: ""}), do: []
  defp rows(%{body: body}) when is_list(body), do: body
  defp rows(%{body: body}), do: body

  defp meta(%{status: status, headers: headers}) do
    %{count: parse_count(headers), status: status}
  end

  defp empty_meta, do: %{count: 0, status: 200}

  @doc """
  Parses the total row count out of a `Content-Range` response header.

  PostgREST reports the range as `<lower>-<upper>/<total>`, using `*` for a
  total it was not asked to compute (`0-14/*`) and for the range half when the
  result is empty (`*/0`).

      iex> AshSupabase.PostgREST.parse_count(%{"content-range" => ["0-24/3573"]})
      3573
      iex> AshSupabase.PostgREST.parse_count(%{"content-range" => ["*/0"]})
      0
      iex> AshSupabase.PostgREST.parse_count(%{"content-range" => ["0-14/*"]})
      nil
      iex> AshSupabase.PostgREST.parse_count(%{})
      nil
  """
  @spec parse_count(map()) :: non_neg_integer() | nil
  def parse_count(headers) do
    with [value | _] <- Map.get(headers, "content-range", []),
         [_range, total] <- String.split(value, "/", parts: 2),
         {count, ""} <- Integer.parse(total) do
      count
    else
      _ -> nil
    end
  end

  defp ensure_filtered(%Query{filters: []} = query, operation, opts) do
    if Keyword.get(opts, :allow_unfiltered?, false) do
      :ok
    else
      {:error,
       Error.Unsupported.exception(
         feature: {:unfiltered, operation},
         message: """
         Refusing to #{operation} every row in "#{query.table}".

         PostgREST scopes #{String.upcase(to_string(operation))} requests entirely by the query \
         string, so a request with no filters affects the whole table. If that is genuinely what \
         you want, pass `allow_unfiltered?: true`, or set `allow_unfiltered_writes? true` in the \
         resource's `supabase` section.
         """
       )}
    end
  end

  defp ensure_filtered(_query, _operation, _opts), do: :ok
end
