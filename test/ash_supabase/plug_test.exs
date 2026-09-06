defmodule AshSupabase.PlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias AshSupabase.Auth.Claims
  alias AshSupabase.Plug, as: SupabasePlug
  alias AshSupabase.Rls

  @secret "test-jwt-secret-that-is-long-enough-for-hs256"
  @issuer "https://test.supabase.co/auth/v1"

  # No HTTP stub is needed: an HS256 token is verified against the client's
  # `:jwt_secret` entirely inside the BEAM, so these are real tokens going
  # through real verification.
  @client [url: "https://test.supabase.co", api_key: "test-anon-key", jwt_secret: @secret]

  setup do
    on_exit(&Rls.clear_claims/0)
    :ok
  end

  describe "init/1" do
    test "fills in the defaults" do
      opts = SupabasePlug.init(client: @client)

      assert opts[:claims_assign] == :supabase_claims
      assert opts[:user_assign] == :current_user
      assert opts[:put_claims] == true
      assert opts[:on_error] == :halt
      assert opts[:verify] == []
    end

    test "requires a client" do
      assert_raise ArgumentError, ~r/requires a `:client`/, fn ->
        SupabasePlug.init([])
      end
    end

    test "rejects an unusable :on_error" do
      assert_raise ArgumentError, ~r/invalid `:on_error`/, fn ->
        SupabasePlug.init(client: @client, on_error: :explode)
      end

      assert_raise ArgumentError, ~r/invalid `:on_error`/, fn ->
        SupabasePlug.init(client: @client, on_error: fn -> :nope end)
      end
    end

    test "accepts the three documented modes" do
      for mode <- [:halt, :continue, &Function.identity/1, fn conn, _reason -> conn end] do
        assert SupabasePlug.init(client: @client, on_error: mode)[:on_error] == mode
      end
    end
  end

  describe "a valid token" do
    test "assigns the verified claims and an actor" do
      conn = call(bearer(token()))

      refute conn.halted

      assert %Claims{} = claims = conn.assigns.supabase_claims
      assert claims.sub == "user-1"
      assert claims.role == "authenticated"
      assert claims.email == "user-1@example.com"

      assert conn.assigns.current_user == %{
               id: "user-1",
               email: "user-1@example.com",
               phone: nil,
               role: "authenticated",
               app_metadata: %{"provider" => "email"},
               user_metadata: %{"name" => "Ada"}
             }
    end

    test "accepts a lowercase bearer scheme" do
      conn = call(conn(:get, "/") |> put_req_header("authorization", "bearer " <> token()))

      refute conn.halted
      assert conn.assigns.current_user.id == "user-1"
    end

    test "hands the raw claims to AshSupabase.Rls" do
      call(bearer(token()))

      claims = Rls.get_claims()

      assert claims["sub"] == "user-1"
      assert claims["role"] == "authenticated"
      # The token as signed, not the struct: `exp` is still unix seconds.
      assert is_integer(claims["exp"])
    end

    test "leaves AshSupabase.Rls alone with put_claims: false" do
      call(bearer(token()), put_claims: false)

      assert Rls.get_claims() == nil
    end

    test "honors custom assign keys" do
      conn = call(bearer(token()), claims_assign: :jwt, user_assign: :actor)

      assert %Claims{} = conn.assigns.jwt
      assert conn.assigns.actor.id == "user-1"
      refute Map.has_key?(conn.assigns, :supabase_claims)
      refute Map.has_key?(conn.assigns, :current_user)
    end

    test ":user builds the actor from the claims" do
      conn = call(bearer(token()), user: fn claims -> {:user, claims.sub} end)

      assert conn.assigns.current_user == {:user, "user-1"}
    end

    test "forwards :verify options" do
      conn = call(bearer(token()), verify: [issuer: @issuer, audience: "authenticated"])

      refute conn.halted
      assert conn.assigns.current_user.id == "user-1"
    end

    test "an empty email claim becomes nil rather than an empty string" do
      conn = call(bearer(token(%{"email" => "", "phone" => "+15550100"})))

      assert conn.assigns.current_user.email == nil
      assert conn.assigns.current_user.phone == "+15550100"
    end
  end

  describe "on_error: :halt" do
    test "401s a request with no authorization header" do
      conn = call(conn(:get, "/"))

      assert conn.halted
      assert conn.status == 401
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "unauthorized",
               "message" => "A valid Supabase access token is required."
             }

      assert SupabasePlug.error_reason(conn) == :missing_token
    end

    test "401s a malformed authorization header" do
      for value <- ["Token abcdef", "Bearer", "Bearer ", "abcdef", ""] do
        conn = call(conn(:get, "/") |> put_req_header("authorization", value))

        assert conn.status == 401, "expected #{inspect(value)} to be rejected"
        assert conn.halted
        assert SupabasePlug.error_reason(conn) == :invalid_authorization_header
      end
    end

    test "401s an expired token" do
      expired = token(%{"exp" => System.system_time(:second) - 60})

      conn = call(bearer(expired))

      assert conn.status == 401
      assert SupabasePlug.error_reason(conn) == :token_expired
    end

    test "401s a token signed with a different secret" do
      forged = token(%{"role" => "service_role"}, secret: "not-the-projects-jwt-secret-at-all")

      conn = call(bearer(forged))

      assert conn.status == 401
      assert SupabasePlug.error_reason(conn) == :signature_error
    end

    test "401s a token from another project when the issuer is pinned" do
      other = token(%{"iss" => "https://someone-else.supabase.co/auth/v1"})

      conn = call(bearer(other), verify: [issuer: @issuer])

      assert conn.status == 401

      assert SupabasePlug.error_reason(conn) ==
               {:invalid_issuer, "https://someone-else.supabase.co/auth/v1"}
    end

    test "401s a token that is not a JWT at all" do
      conn = call(bearer("nonsense"))

      assert conn.status == 401
      assert SupabasePlug.error_reason(conn) == :token_malformed
    end

    test "does not put anything in AshSupabase.Rls" do
      call(bearer(token(%{"exp" => System.system_time(:second) - 60})))

      assert Rls.get_claims() == nil
    end
  end

  describe "on_error: :continue" do
    test "assigns nil and carries on" do
      conn = call(conn(:get, "/"), on_error: :continue)

      refute conn.halted
      assert conn.status == nil
      assert conn.assigns.supabase_claims == nil
      assert conn.assigns.current_user == nil
      assert SupabasePlug.error_reason(conn) == :missing_token
    end

    test "assigns nil to custom keys too" do
      conn =
        call(bearer("nonsense"),
          on_error: :continue,
          claims_assign: :jwt,
          user_assign: :actor
        )

      assert conn.assigns.jwt == nil
      assert conn.assigns.actor == nil
      assert SupabasePlug.error_reason(conn) == :token_malformed
    end
  end

  describe "on_error: a function" do
    test "a 1-arity function gets the conn and can read the reason" do
      on_error = fn conn ->
        conn
        |> assign(:rejected, SupabasePlug.error_reason(conn))
        |> send_resp(403, "nope")
        |> halt()
      end

      conn = call(bearer("nonsense"), on_error: on_error)

      assert conn.halted
      assert conn.status == 403
      assert conn.resp_body == "nope"
      assert conn.assigns.rejected == :token_malformed
    end

    test "a 2-arity function is handed the reason as well" do
      on_error = fn conn, reason -> assign(conn, :rejected, reason) end

      conn = call(conn(:get, "/"), on_error: on_error)

      refute conn.halted
      assert conn.assigns.rejected == :missing_token
    end
  end

  defp call(conn, opts \\ []) do
    SupabasePlug.call(conn, SupabasePlug.init(Keyword.put_new(opts, :client, @client)))
  end

  defp bearer(token) do
    conn(:get, "/") |> put_req_header("authorization", "Bearer " <> token)
  end

  defp token(overrides \\ %{}, opts \\ []) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "sub" => "user-1",
          "aud" => "authenticated",
          "iss" => @issuer,
          "role" => "authenticated",
          "email" => "user-1@example.com",
          "phone" => "",
          "exp" => now + 3600,
          "iat" => now,
          "session_id" => "session-1",
          "is_anonymous" => false,
          "app_metadata" => %{"provider" => "email"},
          "user_metadata" => %{"name" => "Ada"}
        },
        overrides
      )

    {:ok, token} =
      Joken.Signer.sign(claims, Joken.Signer.create("HS256", Keyword.get(opts, :secret, @secret)))

    token
  end
end
