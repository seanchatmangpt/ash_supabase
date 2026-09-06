defmodule AshSupabase.PostgREST.EncoderTest do
  use ExUnit.Case, async: true

  alias AshSupabase.PostgREST.Encoder

  doctest AshSupabase.PostgREST.Encoder

  describe "value/1 quoting" do
    test "leaves values with no reserved characters bare" do
      assert Encoder.value("simple") == "simple"
      assert Encoder.value("with-dash_and_underscore") == "with-dash_and_underscore"

      assert Encoder.value("550e8400-e29b-41d4-a716-446655440000") ==
               "550e8400-e29b-41d4-a716-446655440000"
    end

    test "quotes every PostgREST reserved character" do
      for {input, reason} <- [
            {"a,b", "comma delimits in-lists"},
            {"a.b", "dot delimits column.operator.value"},
            {"a:b", "colon"},
            {"a(b", "open paren delimits groups"},
            {"a)b", "close paren delimits groups"},
            {"a*b", "asterisk aliases % in like patterns"}
          ] do
        assert String.starts_with?(Encoder.value(input), "\""), reason
        assert String.ends_with?(Encoder.value(input), "\""), reason
      end
    end

    test "quotes values with leading or trailing whitespace, which would otherwise be lost" do
      assert Encoder.value(" padded ") == "\" padded \""
      assert Encoder.value("has space") == "\"has space\""
    end

    test "quotes the empty string so it is not read as a missing value" do
      assert Encoder.value("") == "\"\""
    end

    test "escapes quotes and backslashes inside a quoted value" do
      assert Encoder.value(~S|say "hi"|) == ~S|"say \"hi\""|
      assert Encoder.value("back\\slash") == ~S|"back\\slash"|
    end
  end

  describe "literal/1 term conversion" do
    test "converts scalars" do
      assert Encoder.literal(42) == "42"
      assert Encoder.literal(true) == "true"
      assert Encoder.literal(false) == "false"
      assert Encoder.literal(nil) == "null"
      assert Encoder.literal(:published) == "published"
    end

    test "converts temporal types to ISO 8601" do
      assert Encoder.literal(~D[2024-01-31]) == "2024-01-31"
      assert Encoder.literal(~T[13:45:00]) == "13:45:00"
      assert Encoder.literal(~N[2024-01-31 13:45:00]) == "2024-01-31T13:45:00"
      assert Encoder.literal(~U[2024-01-31 13:45:00Z]) == "2024-01-31T13:45:00Z"
    end

    test "renders decimals without scientific notation" do
      assert Encoder.literal(Decimal.new("0.00000001")) == "0.00000001"
      assert Encoder.literal(Decimal.new("1E+10")) == "10000000000"
    end

    test "unwraps case-insensitive strings" do
      assert Encoder.literal(Ash.CiString.new("HELLO")) == "HELLO"
    end

    test "encodes maps and lists as JSON, for jsonb columns" do
      assert Encoder.literal(%{"a" => 1}) == ~S|{"a":1}|
    end
  end

  describe "in_list/1" do
    test "wraps in parentheses, not braces" do
      assert Encoder.in_list([1, 2, 3]) == "(1,2,3)"
    end

    test "quotes elements containing the list delimiter" do
      assert Encoder.in_list(["Hebdon,John", "Williams,Mary"]) ==
               ~S|("Hebdon,John","Williams,Mary")|
    end

    test "handles an empty list" do
      assert Encoder.in_list([]) == "()"
    end
  end

  describe "array/1" do
    test "uses curly braces, as Postgres array literals require" do
      assert Encoder.array([1, 2, 3]) == "{1,2,3}"
    end

    test "quotes elements containing braces, commas or spaces" do
      assert Encoder.array(["a b", "c,d", "{e}"]) == ~S|{"a b","c,d","{e}"}|
    end
  end

  describe "escape_like/1" do
    test "neutralizes SQL LIKE wildcards so user input cannot widen the match" do
      assert Encoder.escape_like("50%") == "50\\%"
      assert Encoder.escape_like("a_b") == "a\\_b"
      assert Encoder.escape_like("back\\slash") == "back\\\\slash"
    end
  end

  describe "like_pattern/2" do
    test "anchors the pattern according to position" do
      assert Encoder.like_pattern("ash", :contains) == "%ash%"
      assert Encoder.like_pattern("ash", :starts_with) == "ash%"
      assert Encoder.like_pattern("ash", :ends_with) == "%ash"
    end

    test "escapes the literal before adding wildcards" do
      # The user's `%` stays literal; only the outer wildcards are live.
      assert Encoder.like_pattern("100%", :contains) == "%100\\%%"
    end
  end
end
