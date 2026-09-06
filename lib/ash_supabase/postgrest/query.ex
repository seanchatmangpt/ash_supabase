defmodule AshSupabase.PostgREST.Query do
  @moduledoc """
  A composable description of a PostgREST request.

  A query is built up field by field — this mirrors how `Ash.DataLayer` hands a
  data layer one concern at a time (`filter/3`, then `sort/3`, then `limit/3`,
  and so on) — and is only turned into query parameters and headers at the
  moment the request is sent.

      iex> alias AshSupabase.PostgREST.Query
      iex> Query.new("posts")
      ...> |> Query.select([:id, :title])
      ...> |> Query.add_filters([{"status", "eq.published"}])
      ...> |> Query.order([{:inserted_at, :desc}])
      ...> |> Query.limit(10)
      ...> |> Query.to_params()
      [{"select", "id,title"}, {"status", "eq.published"}, {"order", "inserted_at.desc"}, {"limit", "10"}]

  ## Impossible queries

  When a filter can never match — `Ash.Query.filter(id in [])`, for example —
  `AshSupabase.PostgREST.Filter` reports it and `impossible/1` marks the query.
  `AshSupabase.PostgREST.run/3` then returns an empty result without making an
  HTTP request at all.
  """

  alias AshSupabase.PostgREST.Encoder

  @type order_direction ::
          :asc | :desc | :asc_nils_first | :asc_nils_last | :desc_nils_first | :desc_nils_last

  @type t :: %__MODULE__{
          table: String.t(),
          select: [String.t()] | nil,
          filters: [{String.t(), String.t()}],
          order: [{String.t(), order_direction()}],
          limit: non_neg_integer() | nil,
          offset: non_neg_integer() | nil,
          count: :exact | :planned | :estimated | nil,
          schema: String.t() | nil,
          returning?: boolean(),
          on_conflict: [String.t()] | nil,
          resolution: :merge_duplicates | :ignore_duplicates | nil,
          single?: boolean(),
          headers: [{String.t(), String.t()}],
          impossible?: boolean(),
          context: map()
        }

  defstruct [
    :table,
    :select,
    :limit,
    :offset,
    :count,
    :schema,
    :on_conflict,
    :resolution,
    filters: [],
    order: [],
    returning?: true,
    single?: false,
    headers: [],
    impossible?: false,
    context: %{}
  ]

  @doc "Builds a query against `table`."
  @spec new(String.t()) :: t()
  def new(table) when is_binary(table), do: %__MODULE__{table: table}

  @doc """
  Restricts the columns returned.

  Passing `nil` (the default) selects every column. An empty list still selects
  the primary key columns the caller supplies, since PostgREST has no way to
  return zero columns.
  """
  @spec select(t(), [atom() | String.t()] | nil) :: t()
  def select(query, nil), do: %{query | select: nil}

  def select(query, columns) do
    %{query | select: Enum.map(columns, &to_string/1)}
  end

  @doc "Adds already-encoded filter parameters, as produced by `AshSupabase.PostgREST.Filter`."
  @spec add_filters(t(), [{String.t(), String.t()}] | :none | :impossible) :: t()
  def add_filters(query, :none), do: query
  def add_filters(query, :impossible), do: impossible(query)

  def add_filters(query, filters) when is_list(filters) do
    %{query | filters: query.filters ++ filters}
  end

  @doc "Marks the query as unable to match any row."
  @spec impossible(t()) :: t()
  def impossible(query), do: %{query | impossible?: true}

  @doc """
  Sets the sort order, replacing any existing one.

  Accepts Ash's sort format: a list of `{field, direction}` where direction is
  one of `:asc`, `:desc`, `:asc_nils_first`, `:asc_nils_last`,
  `:desc_nils_first`, `:desc_nils_last`.
  """
  @spec order(t(), [{atom() | String.t(), order_direction()}]) :: t()
  def order(query, sort) do
    %{query | order: Enum.map(sort, fn {field, direction} -> {to_string(field), direction} end)}
  end

  @doc "Limits the number of rows returned."
  @spec limit(t(), non_neg_integer() | nil) :: t()
  def limit(query, limit), do: %{query | limit: limit}

  @doc "Skips the first `offset` rows."
  @spec offset(t(), non_neg_integer() | nil) :: t()
  def offset(query, offset), do: %{query | offset: offset}

  @doc """
  Requests a row count, returned in the `Content-Range` response header.

  `:exact` runs a real `COUNT(*)`; `:planned` and `:estimated` trade accuracy
  for speed on large tables.
  """
  @spec count(t(), :exact | :planned | :estimated | nil) :: t()
  def count(query, count), do: %{query | count: count}

  @doc "Overrides the Postgres schema for this query."
  @spec schema(t(), String.t() | nil) :: t()
  def schema(query, schema), do: %{query | schema: schema}

  @doc "Whether writes should return the affected rows. Defaults to `true`."
  @spec returning(t(), boolean()) :: t()
  def returning(query, returning?), do: %{query | returning?: returning?}

  @doc """
  Configures upsert behaviour for an insert.

  `columns` names the unique constraint to conflict on; passing `[]` or `nil`
  uses the table's primary key.
  """
  @spec upsert(t(), [atom() | String.t()] | nil, :merge_duplicates | :ignore_duplicates) :: t()
  def upsert(query, columns, resolution \\ :merge_duplicates) do
    %{
      query
      | on_conflict: columns && Enum.map(columns, &to_string/1),
        resolution: resolution
    }
  end

  @doc """
  Requests a single object rather than an array.

  Sends `Accept: application/vnd.pgrst.object+json`, which makes PostgREST
  return a bare object and fail with `PGRST116` unless exactly one row matches.
  """
  @spec single(t(), boolean()) :: t()
  def single(query, single? \\ true), do: %{query | single?: single?}

  @doc "Adds extra headers to the request."
  @spec add_headers(t(), [{String.t(), String.t()}]) :: t()
  def add_headers(query, headers), do: %{query | headers: query.headers ++ headers}

  @doc "Merges values into the query's free-form context."
  @spec put_context(t(), map()) :: t()
  def put_context(query, context), do: %{query | context: Map.merge(query.context, context)}

  @doc """
  Renders the query as an ordered list of query-string parameters.

  A list rather than a map, because PostgREST relies on repeated keys: two
  filters on the same column arrive as `id=gt.5&id=lt.10`.
  """
  @spec to_params(t()) :: [{String.t(), String.t()}]
  def to_params(%__MODULE__{} = query) do
    []
    |> maybe_put("select", select_param(query))
    |> Kernel.++(query.filters)
    |> maybe_put("order", order_param(query))
    |> maybe_put("limit", query.limit && to_string(query.limit))
    |> maybe_put("offset", query.offset && to_string(query.offset))
    |> maybe_put("on_conflict", query.on_conflict && Enum.join(query.on_conflict, ","))
  end

  @doc """
  Renders the request headers implied by the query, including the `Prefer`
  header assembled from `:returning?`, `:count` and `:resolution`.
  """
  @spec to_headers(t()) :: [{String.t(), String.t()}]
  def to_headers(%__MODULE__{} = query) do
    prefer =
      []
      |> prefer(query.returning?, "return=representation")
      |> prefer(query.count, "count=#{query.count}")
      |> prefer(query.resolution == :merge_duplicates, "resolution=merge-duplicates")
      |> prefer(query.resolution == :ignore_duplicates, "resolution=ignore-duplicates")
      |> Enum.reverse()

    accept =
      if query.single? do
        [{"accept", "application/vnd.pgrst.object+json"}]
      else
        []
      end

    headers =
      case prefer do
        [] -> []
        parts -> [{"prefer", Enum.join(parts, ",")}]
      end

    headers ++ accept ++ query.headers
  end

  @doc "The request path for this query, e.g. `/rest/v1/posts`."
  @spec path(t()) :: String.t()
  def path(%__MODULE__{table: table}), do: "/rest/v1/" <> URI.encode(table)

  defp select_param(%{select: nil}), do: nil
  defp select_param(%{select: []}), do: nil
  defp select_param(%{select: columns}), do: Enum.join(columns, ",")

  defp order_param(%{order: []}), do: nil

  defp order_param(%{order: order}) do
    Enum.map_join(order, ",", fn {field, direction} ->
      field <> direction_suffix(direction)
    end)
  end

  # PostgREST requires direction before null placement, and rejects the reverse.
  defp direction_suffix(:asc), do: ".asc"
  defp direction_suffix(:desc), do: ".desc"
  defp direction_suffix(:asc_nils_first), do: ".asc.nullsfirst"
  defp direction_suffix(:asc_nils_last), do: ".asc.nullslast"
  defp direction_suffix(:desc_nils_first), do: ".desc.nullsfirst"
  defp direction_suffix(:desc_nils_last), do: ".desc.nullslast"

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: params ++ [{key, value}]

  defp prefer(parts, nil, _value), do: parts
  defp prefer(parts, false, _value), do: parts
  defp prefer(parts, _truthy, value), do: [value | parts]

  @doc false
  # Exposed for the data layer, which needs to encode a raw value the same way
  # filters do when building an upsert conflict target.
  def encode_value(value), do: Encoder.value(value)
end
