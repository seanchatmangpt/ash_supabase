defmodule AshSupabase.Case do
  @moduledoc """
  Test case that stubs the Supabase HTTP API with `Req.Test`.

  `expect_request/1` installs a stub and captures the request the code under
  test actually made, so assertions can be made on the exact query string,
  headers and body rather than only on the decoded result.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import AshSupabase.Case

      alias AshSupabase.Test.Client, as: TestClient
    end
  end

  @doc """
  Stubs the next request and returns a function that yields the captured `Plug.Conn`.

  `responder` receives the conn and must send a response.

      capture = expect_request(fn conn -> Req.Test.json(conn, [%{"id" => 1}]) end)
      # ... run code ...
      conn = capture.()
      assert conn.query_string == "select=id"
  """
  def expect_request(responder) do
    parent = self()
    ref = make_ref()

    Req.Test.stub(AshSupabase.Test.Client, fn conn ->
      {:ok, body, conn} = read_body(conn)
      send(parent, {ref, %{conn | private: Map.put(conn.private, :raw_body, body)}})
      responder.(conn)
    end)

    fn ->
      receive do
        {^ref, conn} -> conn
      after
        1_000 -> flunk("no request was made")
      end
    end
  end

  @doc "The parsed JSON body of a captured request, or `nil` when there was none."
  def request_body(conn) do
    case conn.private[:raw_body] do
      nil -> nil
      "" -> nil
      body -> Jason.decode!(body)
    end
  end

  @doc "The raw, undecoded body of a captured request."
  def raw_body(conn), do: conn.private[:raw_body]

  @doc "Query parameters of a captured request, as a list of 2-tuples preserving duplicates."
  def query_params(conn) do
    conn.query_string
    |> URI.query_decoder()
    |> Enum.to_list()
  end

  @doc "A single request header value, or nil."
  def header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp read_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:ok, "", conn}
      {:error, _} -> {:ok, "", conn}
    end
  end
end
