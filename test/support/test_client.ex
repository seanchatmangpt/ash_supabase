defmodule AshSupabase.Test.Client do
  @moduledoc false
  use AshSupabase.Client

  @impl true
  def config do
    [
      url: "https://test.supabase.co",
      api_key: "test-anon-key",
      jwt_secret: "test-jwt-secret-that-is-long-enough-for-hs256",
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    ]
  end
end
