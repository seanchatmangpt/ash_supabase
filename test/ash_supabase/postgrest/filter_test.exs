defmodule AshSupabase.PostgREST.FilterTest do
  use ExUnit.Case, async: true

  alias AshSupabase.Error
  alias AshSupabase.PostgREST.Filter
  alias AshSupabase.Test.Blog.Post

  require Ash.Query

  defp params(query), do: Filter.to_params(query.filter, Post)

  defp translate(query) do
    case params(query) do
      {:ok, params} -> params
      {:error, error} -> flunk("expected a translation, got: #{Exception.message(error)}")
    end
  end

  describe "comparison operators" do
    test "equality" do
      assert translate(Ash.Query.filter(Post, title == "hello")) == [{"title", "eq.hello"}]
    end

    test "inequality" do
      assert translate(Ash.Query.filter(Post, title != "hello")) == [{"title", "neq.hello"}]
    end

    test "ordering comparisons" do
      assert translate(Ash.Query.filter(Post, views > 10)) == [{"views", "gt.10"}]
      assert translate(Ash.Query.filter(Post, views >= 10)) == [{"views", "gte.10"}]
      assert translate(Ash.Query.filter(Post, views < 10)) == [{"views", "lt.10"}]
      assert translate(Ash.Query.filter(Post, views <= 10)) == [{"views", "lte.10"}]
    end

    test "membership uses parentheses, not braces" do
      assert translate(Ash.Query.filter(Post, title in ["a", "b"])) ==
               [{"title", "in.(a,b)"}]
    end

    test "an empty `in` list can never match, so no request is needed" do
      assert {:ok, :impossible} = params(Ash.Query.filter(Post, title in []))
    end
  end

  describe "null handling" do
    test "equality against nil becomes `is.null`, since `eq.null` compares to the string" do
      assert translate(Ash.Query.filter(Post, is_nil(body))) == [{"body", "is.null"}]
    end

    test "inequality against nil becomes `not.is.null`" do
      assert translate(Ash.Query.filter(Post, not is_nil(body))) == [{"body", "not.is.null"}]
      assert translate(Ash.Query.filter(Post, not is_nil(body))) == [{"body", "not.is.null"}]
    end

    test "an ordering comparison against nil is never true in SQL" do
      expression = %Ash.Query.Operator.GreaterThan{
        left: %Ash.Query.Ref{attribute: :views, relationship_path: []},
        right: nil
      }

      assert {:ok, :impossible} = Filter.to_params(expression, Post)
    end
  end

  describe "attribute sources" do
    test "uses the column name, not the attribute name" do
      assert translate(Ash.Query.filter(Post, published? == true)) ==
               [{"is_published", "eq.true"}]
    end
  end

  describe "value encoding" do
    test "quotes values containing reserved characters" do
      assert translate(Ash.Query.filter(Post, title == "a,b")) == [{"title", ~S|eq."a,b"|}]
    end

    test "renders atoms as their string value" do
      assert translate(Ash.Query.filter(Post, status == :published)) ==
               [{"status", "eq.published"}]
    end
  end

  describe "boolean logic" do
    test "top-level `and` becomes separate parameters, which PostgREST ANDs" do
      assert translate(Ash.Query.filter(Post, title == "a" and views > 1)) ==
               [{"title", "eq.a"}, {"views", "gt.1"}]
    end

    test "`or` becomes a top-level group carrying an `=`" do
      assert translate(Ash.Query.filter(Post, title == "a" or views > 1)) ==
               [{"or", "(title.eq.a,views.gt.1)"}]
    end

    test "a nested group drops the `=` — emitting `and=(...)` inside would be a parse error" do
      query = Ash.Query.filter(Post, title == "a" or (views > 1 and views < 10))

      # Ash normalizes operand order, putting the compound branch first. What
      # matters is that the inner group has no `=`.
      assert [{"or", value}] = translate(query)
      assert value == "(and(views.gt.1,views.lt.10),title.eq.a)"
      refute String.contains?(value, "and=(")
      refute String.contains?(value, "or=(")
    end

    test "same-operator groups flatten rather than nesting pointlessly" do
      query = Ash.Query.filter(Post, title == "a" or title == "b" or title == "c")

      assert [{"or", "(title.eq.a,title.eq.b,title.eq.c)"}] = translate(query)
    end

    test "an `and` nested inside a top-level `and` still flattens to parameters" do
      query = Ash.Query.filter(Post, title == "a" and (views > 1 and views < 10))

      assert translate(query) == [{"views", "gt.1"}, {"views", "lt.10"}, {"title", "eq.a"}]
    end

    test "repeated filters on one column are preserved as duplicate keys" do
      params = translate(Ash.Query.filter(Post, views > 1 and views < 10))

      assert params == [{"views", "gt.1"}, {"views", "lt.10"}]
      assert length(params) == 2
    end
  end

  describe "negation" do
    test "negates a single comparison with the `not.` operator prefix" do
      assert translate(Ash.Query.filter(Post, not (title == "a"))) == [{"title", "not.eq.a"}]
    end

    test "double negation cancels" do
      # Built directly, because `not (not (...))` parses as an Elixir block
      # rather than as nested negation.
      eq = %Ash.Query.Operator.Eq{
        left: %Ash.Query.Ref{attribute: :title, relationship_path: []},
        right: "a"
      }

      expression = %Ash.Query.Not{expression: %Ash.Query.Not{expression: eq}}

      assert {:ok, [{"title", "eq.a"}]} = Filter.to_params(expression, Post)
    end

    test "negating a group applies De Morgan, so no negated group is ever nested" do
      query = Ash.Query.filter(Post, not (title == "a" or views > 1))

      # not (a or b) == (not a) and (not b) — which flattens to parameters.
      assert translate(query) == [{"title", "not.eq.a"}, {"views", "not.gt.1"}]
    end

    test "negating a nested group keeps the nested form valid" do
      query = Ash.Query.filter(Post, not (title == "a" and (views > 1 or views < 10)))

      assert [{"or", value}] = translate(query)
      assert value == "(and(views.not.gt.1,views.not.lt.10),title.not.eq.a)"
    end
  end

  describe "string functions" do
    test "contains becomes a like pattern with escaped wildcards" do
      # `%` is not a PostgREST reserved character, so the pattern needs no quoting.
      assert translate(Ash.Query.filter(Post, contains(title, "ash"))) ==
               [{"title", "like.%ash%"}]
    end

    test "user wildcards in a contains term are neutralized" do
      assert [{"title", value}] = translate(Ash.Query.filter(Post, contains(title, "100%")))
      assert value == ~S|like."%100\\%%"|
    end
  end

  describe "unsupported expressions" do
    test "relationship filters are refused rather than approximated" do
      assert {:error, %Error.Unsupported{}} =
               Filter.to_params(
                 %Ash.Query.Operator.Eq{
                   left: %Ash.Query.Ref{attribute: :name, relationship_path: [:author]},
                   right: "x"
                 },
                 Post
               )
    end

    test "column-to-column comparison is refused" do
      assert {:error, %Error.Unsupported{} = error} =
               Filter.to_params(
                 %Ash.Query.Operator.Eq{
                   left: %Ash.Query.Ref{attribute: :title, relationship_path: []},
                   right: %Ash.Query.Ref{attribute: :body, relationship_path: []}
                 },
                 Post
               )

      assert Exception.message(error) =~ "another column"
    end

    test "the supported expression list matches what translate actually handles" do
      assert Ash.Query.Operator.Eq in Filter.supported_expressions()
      assert Ash.Query.BooleanExpression in Filter.supported_expressions()
      refute Ash.Query.Function.Fragment in Filter.supported_expressions()
    end
  end

  describe "constant folding" do
    # `title in []` can never match. Under `and` that makes the whole
    # expression impossible; under `or` it must simply disappear, leaving the
    # other branch. Collapsing the `or` case would skip the request entirely
    # and return no rows for a query that should return some.
    setup do
      impossible = %Ash.Query.Operator.In{
        left: %Ash.Query.Ref{attribute: :title, relationship_path: []},
        right: []
      }

      possible = %Ash.Query.Operator.Eq{
        left: %Ash.Query.Ref{attribute: :body, relationship_path: []},
        right: "x"
      }

      {:ok, impossible: impossible, possible: possible}
    end

    test "an impossible branch absorbs an `and`", ctx do
      expression = %Ash.Query.BooleanExpression{
        op: :and,
        left: ctx.impossible,
        right: ctx.possible
      }

      assert {:ok, :impossible} = Filter.to_params(expression, Post)
    end

    test "an impossible branch vanishes from an `or`", ctx do
      expression = %Ash.Query.BooleanExpression{
        op: :or,
        left: ctx.impossible,
        right: ctx.possible
      }

      assert {:ok, [{"body", "eq.x"}]} = Filter.to_params(expression, Post)
    end

    test "an impossible branch vanishes from an `or` on either side", ctx do
      expression = %Ash.Query.BooleanExpression{
        op: :or,
        left: ctx.possible,
        right: ctx.impossible
      }

      assert {:ok, [{"body", "eq.x"}]} = Filter.to_params(expression, Post)
    end

    test "an `or` of two impossible branches is still impossible", ctx do
      expression = %Ash.Query.BooleanExpression{
        op: :or,
        left: ctx.impossible,
        right: ctx.impossible
      }

      assert {:ok, :impossible} = Filter.to_params(expression, Post)
    end
  end

  describe "trivial filters" do
    test "no filter means no parameters" do
      assert {:ok, :none} = Filter.to_params(nil, Post)
    end
  end
end
