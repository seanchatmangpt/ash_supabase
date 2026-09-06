defmodule AshSupabase.PostgREST.Encoder do
  @moduledoc """
  Encodes Elixir terms into PostgREST query-string literals.

  PostgREST gives `.`, `,`, `:`, `*`, `(` and `)` meaning inside filter values:
  they separate the column, the operator and the value, delimit `in` lists,
  delimit logical groups, and stand in for `%` in `like` patterns. A value
  containing any of them must be double quoted, and inside those quotes `"` and
  `\\` must be backslash-escaped.

  Getting this wrong is not a formatting problem — it silently changes which
  rows match. This module applies one uniform rule so that a value is encoded
  identically whether it appears at the top level (`name=eq.<value>`), inside an
  `in` list, or nested in an `or=(...)` group.

  ## Examples

      iex> alias AshSupabase.PostgREST.Encoder
      iex> Encoder.value("simple")
      "simple"
      iex> Encoder.value("has,comma")
      "\\"has,comma\\""
      iex> Encoder.value(~D[2024-01-31])
      "2024-01-31"
      iex> Encoder.value(~U[2024-01-31 13:45:00Z])
      "\\"2024-01-31T13:45:00Z\\""
      iex> Encoder.value(nil)
      "null"
  """

  # Characters PostgREST treats as structural inside a filter value. `*` is
  # included because PostgREST accepts it as an alias for `%` in like/ilike.
  @reserved [",", ".", ":", "*", "(", ")", "\"", "\\"]

  @doc """
  Encodes a term as a PostgREST filter value, quoting when necessary.
  """
  @spec value(term()) :: String.t()
  def value(term) do
    term
    |> literal()
    |> quote_if_needed()
  end

  @doc """
  Encodes a term as a bare PostgREST literal, never quoting.

  Use for grammar positions where quoting is invalid, such as the operand of
  `is` (`is.null`) or the elements of an array literal.
  """
  @spec literal(term()) :: String.t()
  def literal(nil), do: "null"
  def literal(true), do: "true"
  def literal(false), do: "false"
  def literal(term) when is_binary(term), do: term
  def literal(term) when is_integer(term), do: Integer.to_string(term)
  def literal(term) when is_float(term), do: Float.to_string(term)
  def literal(term) when is_atom(term), do: Atom.to_string(term)
  def literal(%Decimal{} = term), do: Decimal.to_string(term, :normal)
  def literal(%Date{} = term), do: Date.to_iso8601(term)
  def literal(%Time{} = term), do: Time.to_iso8601(term)
  def literal(%DateTime{} = term), do: DateTime.to_iso8601(term)
  def literal(%NaiveDateTime{} = term), do: NaiveDateTime.to_iso8601(term)
  def literal(%Ash.CiString{} = term), do: Ash.CiString.value(term)

  def literal(term) when is_list(term) or is_map(term) do
    case Jason.encode(term) do
      {:ok, json} -> json
      {:error, _} -> to_string_safe(term)
    end
  end

  def literal(term), do: to_string_safe(term)

  @doc """
  Encodes the right-hand side of an `in` filter: `("a","b",3)`.

      iex> AshSupabase.PostgREST.Encoder.in_list(["a", "b,c", 3])
      "(a,\\"b,c\\",3)"
  """
  @spec in_list(Enumerable.t()) :: String.t()
  def in_list(values) do
    "(" <> Enum.map_join(values, ",", &value/1) <> ")"
  end

  @doc """
  Encodes a Postgres array literal for the `cs`, `cd` and `ov` operators:
  `{1,2,3}`.

  Elements containing reserved characters are double quoted, matching Postgres
  array-literal syntax.

      iex> AshSupabase.PostgREST.Encoder.array(["a", "b,c"])
      "{a,\\"b,c\\"}"
  """
  @spec array(Enumerable.t()) :: String.t()
  def array(values) do
    inner =
      Enum.map_join(values, ",", fn element ->
        element
        |> literal()
        |> quote_array_element()
      end)

    "{" <> inner <> "}"
  end

  @doc """
  Escapes a string for use as a literal fragment inside a SQL `LIKE`/`ILIKE`
  pattern, so that user input cannot inject wildcards.

  `%`, `_` and `\\` are escaped with the default Postgres escape character.

      iex> AshSupabase.PostgREST.Encoder.escape_like("50%_off")
      "50\\\\%\\\\_off"
  """
  @spec escape_like(term()) :: String.t()
  def escape_like(term) do
    term
    |> literal()
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc """
  Builds a `LIKE` pattern that matches when `term` appears in the given position.

  `position` is `:contains`, `:starts_with` or `:ends_with`.

      iex> AshSupabase.PostgREST.Encoder.like_pattern("ash", :contains)
      "%ash%"
  """
  @spec like_pattern(term(), :contains | :starts_with | :ends_with) :: String.t()
  def like_pattern(term, position) do
    escaped = escape_like(term)

    case position do
      :contains -> "%" <> escaped <> "%"
      :starts_with -> escaped <> "%"
      :ends_with -> "%" <> escaped
    end
  end

  defp quote_if_needed(string) do
    if needs_quoting?(string) do
      "\"" <> escape_quotes(string) <> "\""
    else
      string
    end
  end

  defp needs_quoting?(""), do: true

  defp needs_quoting?(string) do
    Enum.any?(@reserved, &String.contains?(string, &1)) or
      String.trim(string) != string or
      String.contains?(string, [" ", "\t", "\n", "\r"])
  end

  defp quote_array_element(string) do
    if string == "" or
         Enum.any?([",", "{", "}", "\"", "\\", " "], &String.contains?(string, &1)) do
      "\"" <> escape_quotes(string) <> "\""
    else
      string
    end
  end

  defp escape_quotes(string) do
    string
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp to_string_safe(term) do
    if String.Chars.impl_for(term) do
      to_string(term)
    else
      inspect(term)
    end
  end
end
