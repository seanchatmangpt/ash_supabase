defmodule AshSupabase.PostgREST.QueryTest do
  use ExUnit.Case, async: true

  alias AshSupabase.PostgREST.Query

  doctest AshSupabase.PostgREST.Query

  describe "to_params/1" do
    test "an empty query has no parameters" do
      assert Query.to_params(Query.new("posts")) == []
    end

    test "select joins columns with commas" do
      assert Query.new("posts") |> Query.select([:id, :title]) |> Query.to_params() ==
               [{"select", "id,title"}]
    end

    test "an empty select is omitted, since PostgREST cannot return zero columns" do
      assert Query.new("posts") |> Query.select([]) |> Query.to_params() == []
    end

    test "filters keep their order and allow duplicate keys" do
      params =
        Query.new("posts")
        |> Query.add_filters([{"views", "gt.1"}, {"views", "lt.10"}])
        |> Query.to_params()

      assert params == [{"views", "gt.1"}, {"views", "lt.10"}]
    end

    test "order puts direction before null placement, as PostgREST requires" do
      params =
        Query.new("posts")
        |> Query.order([
          {:a, :asc},
          {:b, :desc},
          {:c, :asc_nils_first},
          {:d, :asc_nils_last},
          {:e, :desc_nils_first},
          {:f, :desc_nils_last}
        ])
        |> Query.to_params()

      assert params == [
               {"order",
                "a.asc,b.desc,c.asc.nullsfirst,d.asc.nullslast,e.desc.nullsfirst,f.desc.nullslast"}
             ]
    end

    test "limit and offset are query parameters, not a Range header" do
      params = Query.new("posts") |> Query.limit(10) |> Query.offset(20) |> Query.to_params()

      assert params == [{"limit", "10"}, {"offset", "20"}]
    end

    test "on_conflict names the unique constraint for an upsert" do
      params =
        Query.new("posts") |> Query.upsert([:email, :tenant_id]) |> Query.to_params()

      assert params == [{"on_conflict", "email,tenant_id"}]
    end

    test "a primary-key upsert sends no on_conflict, since that is the default target" do
      assert Query.new("posts") |> Query.upsert(nil) |> Query.to_params() == []
    end
  end

  describe "to_headers/1" do
    test "asks for the affected rows by default" do
      assert Query.to_headers(Query.new("posts")) == [{"prefer", "return=representation"}]
    end

    test "omits the preference when the caller does not want rows back" do
      assert Query.new("posts") |> Query.returning(false) |> Query.to_headers() == []
    end

    test "combines preferences into one comma-separated header" do
      headers =
        Query.new("posts")
        |> Query.count(:exact)
        |> Query.upsert(nil, :merge_duplicates)
        |> Query.to_headers()

      assert [{"prefer", prefer}] = headers
      parts = String.split(prefer, ",")
      assert "return=representation" in parts
      assert "count=exact" in parts
      assert "resolution=merge-duplicates" in parts
    end

    test "ignore-duplicates is distinct from merge-duplicates" do
      assert [{"prefer", prefer}] =
               Query.new("posts")
               |> Query.returning(false)
               |> Query.upsert(nil, :ignore_duplicates)
               |> Query.to_headers()

      assert prefer == "resolution=ignore-duplicates"
    end

    test "single/1 negotiates the object media type" do
      headers = Query.new("posts") |> Query.single() |> Query.to_headers()

      assert {"accept", "application/vnd.pgrst.object+json"} in headers
    end

    test "extra headers are preserved" do
      headers =
        Query.new("posts")
        |> Query.add_headers([{"x-custom", "1"}])
        |> Query.to_headers()

      assert {"x-custom", "1"} in headers
    end
  end

  describe "path/1" do
    test "prefixes the table with the REST route" do
      assert Query.path(Query.new("posts")) == "/rest/v1/posts"
    end

    test "encodes table names containing characters that are not URL safe" do
      assert Query.path(Query.new("Order Items")) == "/rest/v1/Order%20Items"
    end
  end

  describe "impossible queries" do
    test "an impossible filter marks the query" do
      assert Query.new("posts") |> Query.add_filters(:impossible) |> Map.fetch!(:impossible?)
    end

    test "`:none` leaves the query untouched" do
      query = Query.new("posts")
      assert Query.add_filters(query, :none) == query
    end
  end
end
