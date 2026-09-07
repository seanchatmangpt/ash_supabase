defmodule AshSupabase.PostgREST.Filter do
  @moduledoc """
  Translates an `Ash.Filter` expression into PostgREST query parameters.

  ## Why this is not a string concatenation

  PostgREST's filter grammar changes shape with nesting. At the top level a
  comparison is its own parameter and a logical group carries an `=`:

      ?status=eq.published&or=(views.gt.100,featured.is.true)

  Nested inside a group, the same comparison becomes dotted and the group loses
  its `=`:

      ?or=(views.gt.100,and(featured.is.true,pinned.is.false))

  So this module builds an intermediate tree first (`t:node/0`) and renders it
  differently depending on position. Emitting `and=(...)` inside a group is a
  `PGRST100` parse error, not a silently different query.

  ## Unsupported expressions

  Anything with no faithful PostgREST equivalent returns
  `{:error, %AshSupabase.Error.Unsupported{}}` rather than an approximation.
  `c:Ash.DataLayer.can?/2` reports the same set, so Ash will not normally
  send one. See the [data layer guide](data-layer.md#filter-support).
  """

  alias Ash.Query.BooleanExpression
  alias Ash.Query.Function
  alias Ash.Query.Not
  alias Ash.Query.Operator
  alias Ash.Query.Ref
  alias AshSupabase.Error
  alias AshSupabase.PostgREST.Encoder

  @typedoc """
  The intermediate representation.

  * `{:compare, column, operator_and_value}` - a single comparison, where the
    second element is already-encoded, e.g. `"eq.5"` or `"not.is.null"`.
  * `{:group, :and | :or, [node]}` - a logical group.
  * `:always_true` / `:always_false` - constant-folded branches.
  """
  @type node_ ::
          {:compare, String.t(), String.t()}
          | {:group, :and | :or, [node_()]}
          | :always_true
          | :always_false

  @doc """
  Translates a filter into a list of `{key, value}` query parameters.

  Returns `{:ok, params}`, or `{:ok, :none}` when the filter matches everything,
  or `{:ok, :impossible}` when it can never match (so the caller can skip the
  request entirely).
  """
  @spec to_params(Ash.Filter.t() | nil, Ash.Resource.t()) ::
          {:ok, [{String.t(), String.t()}] | :none | :impossible}
          | {:error, Error.Unsupported.t()}
  def to_params(nil, _resource), do: {:ok, :none}
  def to_params(%Ash.Filter{expression: nil}, _resource), do: {:ok, :none}

  def to_params(%Ash.Filter{expression: expression}, resource),
    do: expression |> translate(resource) |> render()

  def to_params(expression, resource), do: expression |> translate(resource) |> render()

  defp render({:error, error}), do: {:error, error}
  defp render({:ok, :always_true}), do: {:ok, :none}
  defp render({:ok, :always_false}), do: {:ok, :impossible}

  # A top-level `and` flattens into separate parameters, which PostgREST ANDs.
  defp render({:ok, {:group, :and, children}}) do
    children
    |> Enum.reduce_while({:ok, []}, fn child, {:ok, acc} ->
      case render_top(child) do
        {:ok, :skip} -> {:cont, {:ok, acc}}
        {:ok, param} -> {:cont, {:ok, [param | acc]}}
        :impossible -> {:halt, {:ok, :impossible}}
      end
    end)
    |> case do
      {:ok, :impossible} -> {:ok, :impossible}
      {:ok, []} -> {:ok, :none}
      {:ok, params} -> {:ok, Enum.reverse(params)}
    end
  end

  defp render({:ok, node}) do
    case render_top(node) do
      {:ok, :skip} -> {:ok, :none}
      {:ok, param} -> {:ok, [param]}
      :impossible -> {:ok, :impossible}
    end
  end

  defp render_top(:always_true), do: {:ok, :skip}
  defp render_top(:always_false), do: :impossible
  defp render_top({:compare, column, operation}), do: {:ok, {column, operation}}

  defp render_top({:group, op, children}) do
    {:ok, {to_string(op), "(" <> Enum.map_join(children, ",", &render_nested/1) <> ")"}}
  end

  # `combine/3` folds constants out of every group, so a constant can never
  # reach a nested position. There is no column-free tautology in PostgREST's
  # grammar, so fail loudly rather than emit a query that means something else.
  defp render_nested(constant) when constant in [:always_true, :always_false] do
    raise ArgumentError,
          "unreachable: constant #{inspect(constant)} inside a logical group. " <>
            "Please report this at https://github.com/seanchatmangpt/ash_supabase/issues"
  end

  defp render_nested({:compare, column, operation}), do: column <> "." <> operation

  # Nested groups drop the `=`: `or=(a.eq.1,and(b.eq.2,c.eq.3))`
  defp render_nested({:group, op, children}) do
    to_string(op) <> "(" <> Enum.map_join(children, ",", &render_nested/1) <> ")"
  end

  # -- translation ----------------------------------------------------------

  defp translate(true, _resource), do: {:ok, :always_true}
  defp translate(false, _resource), do: {:ok, :always_false}
  defp translate(nil, _resource), do: {:ok, :always_true}

  defp translate(%BooleanExpression{op: op, left: left, right: right}, resource) do
    with {:ok, left} <- translate(left, resource),
         {:ok, right} <- translate(right, resource) do
      {:ok, combine(op, left, right)}
    end
  end

  defp translate(%Not{expression: expression}, resource) do
    with {:ok, node} <- translate(expression, resource) do
      negate(node)
    end
  end

  # A bare reference used as a condition means "this boolean column is true".
  defp translate(%Ref{} = ref, resource) do
    with {:ok, column} <- column(ref, resource) do
      {:ok, {:compare, column, "is.true"}}
    end
  end

  defp translate(%Operator.Eq{left: left, right: right}, resource),
    do: comparison(left, right, "eq", resource, nil_op: "is.null")

  defp translate(%Operator.NotEq{left: left, right: right}, resource),
    do: comparison(left, right, "neq", resource, nil_op: "not.is.null")

  defp translate(%Operator.GreaterThan{left: left, right: right}, resource),
    do: comparison(left, right, "gt", resource)

  defp translate(%Operator.GreaterThanOrEqual{left: left, right: right}, resource),
    do: comparison(left, right, "gte", resource)

  defp translate(%Operator.LessThan{left: left, right: right}, resource),
    do: comparison(left, right, "lt", resource)

  defp translate(%Operator.LessThanOrEqual{left: left, right: right}, resource),
    do: comparison(left, right, "lte", resource)

  defp translate(%Operator.In{left: left, right: right}, resource) do
    with {:ok, column} <- column(left, resource),
         {:ok, values} <- literal_list(right) do
      case values do
        [] -> {:ok, :always_false}
        values -> {:ok, {:compare, column, "in." <> Encoder.in_list(values)}}
      end
    end
  end

  defp translate(%Operator.IsNil{left: left, right: right}, resource) do
    with {:ok, column} <- column(left, resource) do
      case right do
        true -> {:ok, {:compare, column, "is.null"}}
        false -> {:ok, {:compare, column, "not.is.null"}}
        other -> unsupported({:is_nil, other})
      end
    end
  end

  defp translate(%Function.IsNil{arguments: [argument]}, resource) do
    with {:ok, column} <- column(argument, resource) do
      {:ok, {:compare, column, "is.null"}}
    end
  end

  # `has` tests array membership, which PostgREST spells as array containment.
  defp translate(%Operator.Has{left: left, right: right}, resource) do
    with {:ok, column} <- column(left, resource),
         {:ok, value} <- literal(right) do
      {:ok, {:compare, column, "cs." <> Encoder.array([value])}}
    end
  end

  defp translate(%Operator.Overlaps{left: left, right: right}, resource) do
    with {:ok, column} <- column(left, resource),
         {:ok, values} <- literal_list(right) do
      {:ok, {:compare, column, "ov." <> Encoder.array(values)}}
    end
  end

  defp translate(%Function.Contains{arguments: [subject, contained]}, resource),
    do: like(subject, contained, :contains, resource)

  defp translate(%Function.StringStartsWith{arguments: [subject, prefix]}, resource),
    do: like(subject, prefix, :starts_with, resource)

  defp translate(%Function.StringEndsWith{arguments: [subject, suffix]}, resource),
    do: like(subject, suffix, :ends_with, resource)

  # `type/3` is a cast wrapper Ash inserts; the cast is PostgREST's job anyway.
  defp translate(%Function.Type{arguments: [inner | _]}, resource),
    do: translate(inner, resource)

  defp translate(%struct{}, _resource), do: unsupported(struct)
  defp translate(other, _resource), do: unsupported(other)

  defp comparison(left, right, operator, resource, opts \\ []) do
    with {:ok, column} <- column(left, resource) do
      compare_against(column, right, operator, opts[:nil_op])
    end
  end

  defp compare_against(column, nil, _operator, nil_op) when is_binary(nil_op),
    do: {:ok, {:compare, column, nil_op}}

  # `gt.null` and friends compare against the four-character string "null" in
  # PostgREST, which is never what Ash means here.
  defp compare_against(_column, nil, _operator, _nil_op), do: {:ok, :always_false}

  defp compare_against(column, right, operator, _nil_op) do
    with {:ok, value} <- literal(right) do
      {:ok, {:compare, column, operator <> "." <> Encoder.value(value)}}
    end
  end

  defp like(subject, pattern, position, resource) do
    with {:ok, column} <- column(subject, resource),
         {:ok, value} <- literal(pattern) do
      operator =
        if case_insensitive?(value) or case_insensitive?(subject), do: "ilike", else: "like"

      encoded = value |> Encoder.like_pattern(position) |> Encoder.value()
      {:ok, {:compare, column, operator <> "." <> encoded}}
    end
  end

  defp case_insensitive?(%Ash.CiString{}), do: true

  defp case_insensitive?(%Ref{attribute: %{type: type}}),
    do: type in [Ash.Type.CiString, :ci_string]

  defp case_insensitive?(_), do: false

  # -- helpers --------------------------------------------------------------

  # Constant folding. Note that a constant absorbs under one operator and
  # vanishes under the other, so these clauses must stay operator-specific: a
  # catch-all on `:always_false` would turn `false or x` into `false`.
  defp combine(:and, :always_false, _right), do: :always_false
  defp combine(:and, _left, :always_false), do: :always_false
  defp combine(:and, :always_true, right), do: right
  defp combine(:and, left, :always_true), do: left
  defp combine(:or, :always_true, _right), do: :always_true
  defp combine(:or, _left, :always_true), do: :always_true
  defp combine(:or, :always_false, right), do: right
  defp combine(:or, left, :always_false), do: left

  # Flatten same-operator groups so `a and b and c` renders as one group.
  defp combine(op, {:group, op, left}, {:group, op, right}), do: {:group, op, left ++ right}
  defp combine(op, {:group, op, left}, right), do: {:group, op, left ++ [right]}
  defp combine(op, left, {:group, op, right}), do: {:group, op, [left | right]}
  defp combine(op, left, right), do: {:group, op, [left, right]}

  defp negate(:always_true), do: {:ok, :always_false}
  defp negate(:always_false), do: {:ok, :always_true}

  defp negate({:compare, column, "not." <> operation}), do: {:ok, {:compare, column, operation}}

  defp negate({:compare, column, operation}) do
    {:ok, {:compare, column, "not." <> operation}}
  end

  # De Morgan: PostgREST supports `not.and=(...)` at the top level, but not a
  # negated group nested inside another group. Pushing the negation down to the
  # leaves keeps one renderer for both positions.
  defp negate({:group, op, children}) do
    flipped = if op == :and, do: :or, else: :and

    children
    |> Enum.reduce_while({:ok, []}, fn child, {:ok, acc} ->
      case negate(child) do
        {:ok, negated} -> {:cont, {:ok, [negated | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, children} -> {:ok, {:group, flipped, Enum.reverse(children)}}
      {:error, error} -> {:error, error}
    end
  end

  defp column(%Ref{relationship_path: [_ | _]} = ref, _resource) do
    unsupported({:relationship_filter, Ref.name(ref)})
  end

  defp column(%Ref{} = ref, resource) do
    name = Ref.name(ref)

    case Ash.Resource.Info.attribute(resource, name) do
      %{source: source} when not is_nil(source) -> {:ok, to_string(source)}
      %{name: name} -> {:ok, to_string(name)}
      # Calculations and aggregates have no column to filter on.
      nil -> unsupported({:non_attribute_reference, name})
    end
  end

  defp column(%struct{}, _resource), do: unsupported({:computed_reference, struct})
  defp column(other, _resource), do: unsupported({:reference, other})

  defp literal(%Ref{} = ref), do: unsupported({:column_to_column_comparison, Ref.name(ref)})

  defp literal(%struct{} = value)
       when struct in [Ash.CiString, Decimal, Date, Time, DateTime, NaiveDateTime],
       do: {:ok, value}

  defp literal(%struct{}), do: unsupported({:expression_operand, struct})
  defp literal(value), do: {:ok, value}

  defp literal_list(%MapSet{} = set), do: set |> MapSet.to_list() |> literal_list()

  defp literal_list(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case literal(value) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, error} -> {:error, error}
    end
  end

  defp literal_list(other), do: unsupported({:list_operand, other})

  defp unsupported(feature) do
    {:error,
     Error.Unsupported.exception(
       feature: feature,
       message: """
       #{describe(feature)}

       The Supabase Data API (PostgREST) has no equivalent for this expression. \
       Either move the filter into a database view or an RPC function and expose \
       that to Ash, or use `AshPostgres` for this resource.
       """
     )}
  end

  defp describe({:relationship_filter, name}),
    do: "Cannot filter on `#{name}` across a relationship."

  defp describe({:column_to_column_comparison, name}),
    do: "Cannot compare a column against another column (`#{name}`)."

  defp describe({:non_attribute_reference, name}),
    do: "Cannot filter on `#{name}`, which is not a stored attribute."

  defp describe(feature), do: "Unsupported filter expression: #{inspect(feature)}."

  @doc """
  The filter expression structs this module can translate.

  `c:Ash.DataLayer.can?/2` uses this to answer `{:filter_expr, struct}`,
  so Ash knows up front which expressions it can push down.
  """
  @spec supported_expressions() :: [module()]
  def supported_expressions do
    [
      BooleanExpression,
      Not,
      Ref,
      Operator.Eq,
      Operator.NotEq,
      Operator.GreaterThan,
      Operator.GreaterThanOrEqual,
      Operator.LessThan,
      Operator.LessThanOrEqual,
      Operator.In,
      Operator.IsNil,
      Operator.Has,
      Operator.Overlaps,
      Function.IsNil,
      Function.Contains,
      Function.StringStartsWith,
      Function.StringEndsWith,
      Function.Type
    ]
  end
end
