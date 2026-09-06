defmodule AshSupabase.DataLayer do
  @moduledoc """
  An `Ash.DataLayer` backed by the Supabase Data API (PostgREST).

  Use this when your application reaches Supabase over HTTPS rather than over a
  Postgres connection — from an environment with no direct database access, or
  when you want every query to run through Row Level Security as a specific
  signed-in user.

      defmodule MyApp.Blog.Post do
        use Ash.Resource,
          domain: MyApp.Blog,
          data_layer: AshSupabase.DataLayer

        supabase do
          table "posts"
          client MyApp.Supabase
        end

        attributes do
          uuid_primary_key :id
          attribute :title, :string, public?: true
          attribute :status, :atom, constraints: [one_of: [:draft, :published]], public?: true
          create_timestamp :inserted_at
        end
      end

  ## Acting as a user

  A request authenticated with the publishable key runs as the `anon` Postgres
  role. To run as a signed-in user instead — which is what makes `auth.uid()`
  and your RLS policies work — put their access token in the data layer context:

      Post
      |> Ash.Query.filter(status == :published)
      |> AshSupabase.DataLayer.with_token(session.access_token)
      |> Ash.read!()

  `AshSupabase.Plug` puts the verified token on the connection, so in a Phoenix
  app this is usually one line in a controller.

  ## Choosing between this and AshPostgres

  This data layer speaks HTTP, so it inherits PostgREST's shape: one table per
  request, no joins, no client-controlled transactions. `AshPostgres` connects
  to the same database directly and supports the whole of Ash. Reach for
  `AshPostgres` when you have a database connection, and this when you do not —
  or use both, resource by resource, in one application.

  ## Limitations

  These are properties of the Data API, not gaps in the implementation. Each is
  reported honestly through `c:Ash.DataLayer.can?/2`, so Ash plans around them
  rather than failing at request time.

    * **No transactions.** PostgREST runs each request in its own transaction
      and offers no way to span several, so `can?(:transact)` is `false`. A
      multi-step action is therefore not atomic. If you need atomicity, put the
      steps in a Postgres function and call it with
      `AshSupabase.PostgREST.rpc/4`.
    * **No joins or relationship filters.** Filtering by a related resource's
      attributes is not supported. Ash still *loads* relationships, with one
      request per relationship.
    * **No aggregates other than count.** `count` is served by PostgREST's
      `Content-Range` header; `sum`, `avg` and friends require the aggregate
      functions PostgREST disables by default.
    * **No atomic updates.** Expression-based updates (`Ash.Changeset.atomic_update/3`)
      have no PostgREST equivalent.
    * **Row cap.** Supabase caps responses at 1000 rows by default. Paginate.

  See the [data layer guide](data-layer.md) for the full picture.
  """

  @behaviour Ash.DataLayer

  alias AshSupabase.DataLayer.Info
  alias AshSupabase.Error
  alias AshSupabase.PostgREST
  alias AshSupabase.PostgREST.Encoder
  alias AshSupabase.PostgREST.Filter
  alias AshSupabase.PostgREST.Query

  @supabase %Spark.Dsl.Section{
    name: :supabase,
    describe: """
    Configures how this resource maps onto a table or view exposed through the
    Supabase Data API.
    """,
    examples: [
      """
      supabase do
        table "posts"
        client MyApp.Supabase
        schema "public"
      end
      """
    ],
    schema: [
      table: [
        type: :string,
        required: true,
        doc: "The table or view name, as exposed through the Data API."
      ],
      client: [
        type: {:behaviour, AshSupabase.Client},
        required: true,
        doc: "The `AshSupabase.Client` module identifying the Supabase project."
      ],
      schema: [
        type: :string,
        doc: """
        The Postgres schema holding the table. Defaults to the client's schema.
        The schema must be listed as an exposed schema in the project's Data API
        settings, or requests fail with `PGRST106`.
        """
      ],
      count_strategy: [
        type: {:one_of, [:exact, :planned, :estimated]},
        default: :exact,
        doc: """
        How to count rows for keyset-free pagination. `:exact` runs a real
        `COUNT(*)`; `:planned` and `:estimated` read the query planner instead,
        which is far cheaper on large tables and correspondingly approximate.
        """
      ],
      allow_unfiltered_writes?: [
        type: :boolean,
        default: false,
        doc: """
        Whether a bulk update or destroy with no filter may run.

        PostgREST scopes writes entirely by the query string, so an unfiltered
        `PATCH` or `DELETE` rewrites or deletes every row in the table. This
        defaults to `false` so that has to be asked for explicitly.
        """
      ],
      headers: [
        type: {:list, {:tuple, [:string, :string]}},
        default: [],
        doc: "Extra headers sent with every request for this resource."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@supabase],
    verifiers: [AshSupabase.DataLayer.Verifiers.VerifyTable]

  @doc """
  Runs this query or changeset as the user the access token belongs to.

  The token is sent as the `Authorization` bearer token, so PostgREST resolves
  the request to the `authenticated` role and RLS policies see the user's
  claims. The token is not verified here — it is passed through — so obtain it
  from `AshSupabase.Auth` or a verified `AshSupabase.Plug` assign.

      Post
      |> AshSupabase.DataLayer.with_token(session.access_token)
      |> Ash.read!()
  """
  @spec with_token(
          Ash.Query.t() | Ash.Changeset.t() | Ash.ActionInput.t() | Ash.Resource.t(),
          String.t()
        ) :: Ash.Query.t() | Ash.Changeset.t() | Ash.ActionInput.t()
  def with_token(resource, token) when is_atom(resource),
    do: resource |> Ash.Query.new() |> with_token(token)

  def with_token(%Ash.Query{} = query, token),
    do: Ash.Query.set_context(query, %{data_layer: %{token: token}})

  def with_token(%Ash.Changeset{} = changeset, token),
    do: Ash.Changeset.set_context(changeset, %{data_layer: %{token: token}})

  def with_token(%Ash.ActionInput{} = input, token),
    do: Ash.ActionInput.set_context(input, %{data_layer: %{token: token}})

  # -- capabilities ---------------------------------------------------------

  @impl true
  def can?(_, :read), do: true
  def can?(_, :create), do: true
  def can?(_, :bulk_create), do: true
  def can?(_, :upsert), do: true
  def can?(_, :filter), do: true
  def can?(_, :boolean_filter), do: true
  def can?(_, :sort), do: true
  def can?(_, {:sort, _type}), do: true
  def can?(_, :limit), do: true
  def can?(_, :offset), do: true
  def can?(_, :select), do: true
  def can?(_, :multitenancy), do: true
  def can?(_, :composite_primary_key), do: true
  def can?(_, :async_engine), do: true
  def can?(_, {:query_aggregate, :count}), do: true
  def can?(_, {:aggregate, :count}), do: true
  # Ash asks this before building any comparison whose operand is a reference,
  # which is to say before building almost any filter at all.
  def can?(_, :nested_expressions), do: true

  def can?(resource, feature)
      when feature in [:update, :destroy, :update_query, :destroy_query] do
    resource |> Ash.Resource.Info.primary_key() |> Enum.any?()
  end

  # Ash passes the expression *instance*, so report on its module. Anything
  # `AshSupabase.PostgREST.Filter` cannot translate faithfully is declined here,
  # which makes Ash refuse the query up front instead of failing mid-request.
  def can?(_, {:filter_expr, %struct{}}), do: struct in Filter.supported_expressions()
  def can?(_, {:filter_expr, _}), do: false

  # PostgREST has no client-controlled transactions: every request commits on
  # its own. Saying so lets Ash avoid planning multi-step atomic work here.
  def can?(_, :transact), do: false

  def can?(_, _), do: false

  @impl true
  def source(resource), do: Info.table(resource)

  # -- query construction ---------------------------------------------------

  @impl true
  def resource_to_query(resource, _domain) do
    resource
    |> Info.table()
    |> Query.new()
    |> Query.schema(Info.schema(resource))
    |> Query.add_headers(Info.headers(resource))
    |> Query.put_context(%{resource: resource})
  end

  @impl true
  def filter(query, filter, resource) do
    case Filter.to_params(filter, resource) do
      {:ok, params} -> {:ok, Query.add_filters(query, params)}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def sort(query, sort, resource) do
    Enum.reduce_while(sort, {:ok, []}, fn {field, direction}, {:ok, acc} ->
      case column(resource, field) do
        {:ok, column} -> {:cont, {:ok, [{column, direction} | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, order} -> {:ok, Query.order(query, Enum.reverse(order))}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def limit(query, limit, _resource), do: {:ok, Query.limit(query, limit)}

  @impl true
  def offset(query, offset, _resource), do: {:ok, Query.offset(query, offset)}

  @impl true
  def select(query, select, resource) do
    # The primary key is always needed, both so Ash can identify records and so
    # that `update`/`destroy` can address them afterwards.
    columns =
      (Ash.Resource.Info.primary_key(resource) ++ List.wrap(select))
      |> Enum.uniq()
      |> Enum.map(&column!(resource, &1))

    {:ok, Query.select(query, columns)}
  end

  @impl true
  def set_tenant(resource, query, tenant) do
    case Ash.Resource.Info.multitenancy_strategy(resource) do
      # Context multitenancy maps onto a Postgres schema, which PostgREST
      # selects with the Accept-Profile / Content-Profile headers.
      :context -> {:ok, Query.schema(query, to_string(tenant))}
      # Attribute multitenancy is expressed as a filter, which Ash adds itself.
      _ -> {:ok, query}
    end
  end

  @impl true
  def set_context(_resource, query, context) do
    {:ok, Query.put_context(query, %{ash_context: context})}
  end

  # -- reads ----------------------------------------------------------------

  @impl true
  def run_query(%Query{} = query, resource) do
    client = Info.client(resource)

    case PostgREST.run(client, query, request_opts(query)) do
      # PostgREST returns an array for a normal read, but a bare object when a
      # singular media type was negotiated. Normalize before casting.
      {:ok, rows, _meta} -> cast_records(List.wrap(rows), resource)
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def run_aggregate_query(%Query{} = query, aggregates, resource) do
    Enum.reduce_while(aggregates, {:ok, %{}}, fn aggregate, {:ok, acc} ->
      case run_aggregate(query, aggregate, resource) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, aggregate.name, value)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp run_aggregate(query, %{kind: :count} = aggregate, resource) do
    client = Info.client(resource)

    counting =
      query
      |> Query.count(Info.count_strategy(resource))
      # A HEAD request asks PostgREST for the Content-Range header without
      # transferring a single row.
      |> Query.limit(nil)
      |> Query.offset(nil)

    with {:ok, filtered} <- apply_aggregate_filter(counting, aggregate, resource) do
      case AshSupabase.Client.request(client, :head, Query.path(filtered),
             params: Query.to_params(filtered),
             headers: Query.to_headers(filtered),
             token: request_opts(query)[:token],
             schema: filtered.schema
           ) do
        {:ok, response} -> {:ok, PostgREST.parse_count(response.headers) || 0}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp run_aggregate(_query, aggregate, resource) do
    {:error,
     Error.Unsupported.exception(
       feature: {:aggregate, aggregate.kind},
       resource: resource,
       message: """
       The Supabase Data API cannot compute a #{inspect(aggregate.kind)} aggregate.

       PostgREST only exposes row counts (via the `Content-Range` header) unless \
       aggregate functions are explicitly enabled, and Supabase disables them by default. \
       Expose a view or a Postgres function that computes this instead, and read it with \
       `AshSupabase.PostgREST.rpc/4`.
       """
     )}
  end

  defp apply_aggregate_filter(query, %{query: %Ash.Query{filter: filter}}, resource)
       when not is_nil(filter) do
    case Filter.to_params(filter, resource) do
      {:ok, params} -> {:ok, Query.add_filters(query, params)}
      {:error, error} -> {:error, error}
    end
  end

  defp apply_aggregate_filter(query, _aggregate, _resource), do: {:ok, query}

  # -- writes ---------------------------------------------------------------

  @impl true
  def create(resource, changeset) do
    with {:ok, attributes} <- dump_changes(changeset, resource) do
      query =
        resource
        |> base_write_query()
        |> Query.single()

      case PostgREST.insert(Info.client(resource), query, attributes, changeset_opts(changeset)) do
        {:ok, row, _meta} -> cast_record(row, resource)
        {:error, error} -> {:error, error}
      end
    end
  end

  @impl true
  def upsert(resource, changeset, keys), do: upsert(resource, changeset, keys, nil)

  @impl true
  def upsert(resource, changeset, keys, _identity) do
    with {:ok, attributes} <- dump_changes(changeset, resource) do
      conflict_columns =
        case keys do
          nil -> nil
          [] -> nil
          keys -> Enum.map(keys, &column!(resource, &1))
        end

      query =
        resource
        |> base_write_query()
        |> Query.upsert(conflict_columns, :merge_duplicates)
        |> Query.single()

      case PostgREST.insert(Info.client(resource), query, attributes, changeset_opts(changeset)) do
        {:ok, row, _meta} -> cast_record(row, resource)
        {:error, error} -> {:error, error}
      end
    end
  end

  @impl true
  def bulk_create(resource, changesets, options) do
    changesets = Enum.to_list(changesets)

    with {:ok, rows} <- dump_all(changesets, resource) do
      query =
        resource
        |> base_write_query()
        |> Query.returning(Map.get(options, :return_records?, false))

      query =
        if Map.get(options, :upsert?, false) do
          Query.upsert(query, upsert_columns(resource, options), :merge_duplicates)
        else
          query
        end

      opts = changesets |> List.first() |> changeset_opts()

      case PostgREST.insert(Info.client(resource), query, rows, opts) do
        {:ok, _rows, _meta} when not query.returning? -> :ok
        {:ok, returned, _meta} -> cast_records(List.wrap(returned), resource)
        {:error, error} -> {:error, error}
      end
    end
  end

  defp upsert_columns(resource, options) do
    case Map.get(options, :upsert_keys) do
      nil -> nil
      [] -> nil
      keys -> Enum.map(keys, &column!(resource, &1))
    end
  end

  @impl true
  def update(resource, changeset) do
    with :ok <- reject_atomics(changeset, resource),
         {:ok, attributes} <- dump_changes(changeset, resource),
         {:ok, query} <- record_query(resource, changeset.data),
         {:ok, query} <- apply_changeset_filter(query, changeset, resource) do
      query = Query.single(query)

      case PostgREST.update(Info.client(resource), query, attributes, changeset_opts(changeset)) do
        {:ok, row, _meta} -> cast_record(row, resource)
        {:error, error} -> {:error, error}
      end
    end
  end

  @impl true
  def destroy(resource, changeset) do
    with {:ok, query} <- record_query(resource, changeset.data),
         {:ok, query} <- apply_changeset_filter(query, changeset, resource) do
      case PostgREST.delete(
             Info.client(resource),
             Query.returning(query, false),
             changeset_opts(changeset)
           ) do
        {:ok, _rows, _meta} -> :ok
        {:error, error} -> {:error, error}
      end
    end
  end

  @impl true
  def update_query(%Query{} = query, changeset, resource, options) do
    with :ok <- reject_atomics(changeset, resource),
         {:ok, attributes} <- dump_changes(changeset, resource) do
      query = Query.returning(query, Map.get(options, :return_records?, false))
      opts = changeset_opts(changeset) ++ unfiltered_opts(resource)

      case PostgREST.update(Info.client(resource), query, attributes, opts) do
        {:ok, _rows, _meta} when not query.returning? -> :ok
        {:ok, rows, _meta} -> cast_records(List.wrap(rows), resource)
        {:error, error} -> {:error, error}
      end
    end
  end

  @impl true
  def destroy_query(%Query{} = query, changeset, resource, options) do
    query = Query.returning(query, Map.get(options, :return_records?, false))
    opts = changeset_opts(changeset) ++ unfiltered_opts(resource)

    case PostgREST.delete(Info.client(resource), query, opts) do
      {:ok, _rows, _meta} when not query.returning? -> :ok
      {:ok, rows, _meta} -> cast_records(List.wrap(rows), resource)
      {:error, error} -> {:error, error}
    end
  end

  # -- helpers --------------------------------------------------------------

  defp base_write_query(resource) do
    resource
    |> Info.table()
    |> Query.new()
    |> Query.schema(Info.schema(resource))
    |> Query.add_headers(Info.headers(resource))
    |> Query.returning(true)
  end

  defp record_query(resource, record) do
    case Ash.Resource.Info.primary_key(resource) do
      [] ->
        {:error,
         Error.Unsupported.exception(
           feature: :no_primary_key,
           resource: resource,
           message: """
           #{inspect(resource)} has no primary key, so a single row cannot be addressed.

           PostgREST identifies rows by filter, not by path, so an update or destroy \
           needs at least one uniquely identifying column.
           """
         )}

      keys ->
        Enum.reduce_while(keys, {:ok, base_write_query(resource)}, fn key, {:ok, query} ->
          add_key_filter(query, resource, record, key)
        end)
    end
  end

  defp add_key_filter(query, resource, record, key) do
    attribute = Ash.Resource.Info.attribute(resource, key)

    case Ash.Type.dump_to_embedded(attribute.type, Map.get(record, key), attribute.constraints) do
      {:ok, value} ->
        filter = {column!(resource, key), "eq." <> Encoder.value(value)}
        {:cont, {:ok, Query.add_filters(query, [filter])}}

      _ ->
        {:halt,
         {:error,
          Ash.Error.Changes.InvalidAttribute.exception(
            field: key,
            message: "could not be encoded as a primary key filter"
          )}}
    end
  end

  defp apply_changeset_filter(query, %{filter: nil}, _resource), do: {:ok, query}

  defp apply_changeset_filter(query, %{filter: filter}, resource) do
    case Filter.to_params(filter, resource) do
      {:ok, params} -> {:ok, Query.add_filters(query, params)}
      {:error, error} -> {:error, error}
    end
  end

  # Atomic updates are Postgres expressions evaluated server-side. PostgREST
  # takes literal values only, so silently dropping them would corrupt data.
  defp reject_atomics(%{atomics: atomics}, resource) when atomics != [] do
    {:error,
     Error.Unsupported.exception(
       feature: {:atomic, :update},
       resource: resource,
       message: """
       Atomic updates are not supported by the Supabase Data API.

       The Data API accepts literal column values, not expressions, so \
       `Ash.Changeset.atomic_update/3` (and the atomic validations built on it) cannot be \
       pushed down. Set `require_atomic? false` on the action, or move the expression into a \
       Postgres function and call it with `AshSupabase.PostgREST.rpc/4`.
       """
     )}
  end

  defp reject_atomics(_changeset, _resource), do: :ok

  defp dump_all(changesets, resource) do
    Enum.reduce_while(changesets, {:ok, []}, fn changeset, {:ok, acc} ->
      case dump_changes(changeset, resource) do
        {:ok, attributes} -> {:cont, {:ok, [attributes | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, error} -> {:error, error}
    end
  end

  defp dump_changes(%{attributes: attributes}, resource) do
    Enum.reduce_while(attributes, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      attribute = Ash.Resource.Info.attribute(resource, name)

      case Ash.Type.dump_to_embedded(attribute.type, value, attribute.constraints) do
        {:ok, dumped} ->
          {:cont, {:ok, Map.put(acc, column!(resource, name), dumped)}}

        _ ->
          {:halt,
           {:error,
            Ash.Error.Changes.InvalidAttribute.exception(
              field: name,
              value: value,
              message: "could not be encoded for the Supabase Data API"
            )}}
      end
    end)
  end

  defp changeset_opts(nil), do: []

  defp changeset_opts(%{context: context}) do
    case get_in(context, [:data_layer, :token]) do
      nil -> []
      token -> [token: token]
    end
  end

  defp changeset_opts(_), do: []

  defp request_opts(%Query{context: context}) do
    case get_in(context, [:ash_context, :data_layer, :token]) do
      nil -> []
      token -> [token: token]
    end
  end

  defp unfiltered_opts(resource) do
    if Info.allow_unfiltered_writes?(resource), do: [allow_unfiltered?: true], else: []
  end

  defp column(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      %{source: source} when not is_nil(source) -> {:ok, to_string(source)}
      %{name: name} -> {:ok, to_string(name)}
      nil -> {:error, unknown_field(resource, name)}
    end
  end

  defp column!(resource, name) do
    case column(resource, name) do
      {:ok, column} -> column
      {:error, error} -> raise error
    end
  end

  defp unknown_field(resource, name) do
    Error.Unsupported.exception(
      feature: {:unknown_field, name},
      resource: resource,
      message: """
      `#{inspect(name)}` is not a stored attribute of #{inspect(resource)}.

      Calculations and aggregates have no column in the table, so the Supabase Data API cannot \
      sort or filter by them. Ash can still compute them in memory after loading.
      """
    )
  end

  @doc false
  # Turns a decoded JSON row into a resource struct, casting each column through
  # its Ash type. Columns are keyed by `source` when the attribute defines one.
  def cast_record(row, resource) when is_map(row) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.reduce_while({:ok, %{}}, &cast_column(&1, &2, row, resource))
    |> case do
      {:ok, attrs} ->
        {:ok,
         %{
           struct(resource, attrs)
           | __meta__: %Ecto.Schema.Metadata{state: :loaded, schema: resource}
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  def cast_record(nil, _resource), do: {:error, :no_record_returned}

  defp cast_column(attribute, {:ok, attrs}, row, resource) do
    case Map.fetch(row, to_string(attribute.source || attribute.name)) do
      # A column the query did not select simply keeps the struct's default.
      :error -> {:cont, {:ok, attrs}}
      {:ok, nil} -> {:cont, {:ok, Map.put(attrs, attribute.name, nil)}}
      {:ok, value} -> cast_value(attribute, value, attrs, resource)
    end
  end

  defp cast_value(attribute, value, attrs, resource) do
    case Ash.Type.cast_stored(attribute.type, value, attribute.constraints) do
      {:ok, casted} ->
        {:cont, {:ok, Map.put(attrs, attribute.name, casted)}}

      _ ->
        {:halt,
         {:error,
          Ash.Error.Invalid.InvalidStoredData.exception(
            resource: resource,
            field: attribute.name
          )}}
    end
  end

  @doc false
  def cast_records(rows, resource) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case cast_record(row, resource) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, error} -> {:error, error}
    end
  end
end
