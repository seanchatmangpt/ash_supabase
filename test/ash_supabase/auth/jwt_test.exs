defmodule AshSupabase.Auth.JWTTest do
  # The JWKS cache is a named ETS table, so the caching tests cannot share the
  # BEAM with other tests that fetch key sets concurrently.
  use AshSupabase.Case, async: false

  alias AshSupabase.Auth.Claims
  alias AshSupabase.Auth.JWKS
  alias AshSupabase.Auth.JWT
  alias AshSupabase.Error

  doctest AshSupabase.Auth.Claims
  doctest AshSupabase.Auth.JWKS
  doctest AshSupabase.Auth.JWT

  @now 1_757_749_466
  @issuer "https://test.supabase.co/auth/v1"
  @secret "test-jwt-secret-that-is-long-enough-for-hs256"
  @req_options [plug: {Req.Test, AshSupabase.Test.Client}, retry: false]

  setup do
    on_exit(&JWKS.clear/0)
    :ok
  end

  describe "HS256 with the legacy shared secret" do
    test "verifies a token and decodes every documented claim" do
      token = hs256(claims())

      assert {:ok, %Claims{} = claims} = JWT.verify(client(), token, now: @now)

      assert claims.sub == "123e4567-e89b-12d3-a456-426614174000"
      assert claims.aud == "authenticated"
      assert claims.iss == @issuer
      assert claims.role == "authenticated"
      assert claims.email == "user@example.com"
      assert claims.phone == ""
      assert claims.app_metadata == %{"provider" => "email"}
      assert claims.user_metadata == %{"full_name" => "Ada"}
      assert claims.session_id == "9f8e7d6c-5b4a-3210-fedc-ba9876543210"
      assert claims.aal == "aal1"
      assert claims.amr == [%{"method" => "password", "timestamp" => @now}]
      assert claims.is_anonymous == false
      assert claims.exp == DateTime.from_unix!(@now + 3600)
      assert claims.iat == DateTime.from_unix!(@now)
      assert claims.raw["scope"] == nil
    end

    test "keeps OAuth-server-only claims reachable through :raw" do
      token = hs256(claims(%{"client_id" => "c1", "scope" => "openid email"}))

      assert {:ok, %Claims{raw: raw}} = JWT.verify(client(), token, now: @now)
      assert raw["client_id"] == "c1"
      assert raw["scope"] == "openid email"
    end

    test "rejects a token signed with a different secret" do
      token = Joken.Signer.create("HS256", "some-other-projects-secret")
      token = sign(claims(), token)

      assert {:error, :signature_error} = JWT.verify(client(), token, now: @now)
    end

    test "rejects an expired token, and honors :leeway" do
      token = hs256(claims(%{"exp" => @now + 10}))

      assert {:error, :token_expired} = JWT.verify(client(), token, now: @now + 20)
      assert {:ok, %Claims{}} = JWT.verify(client(), token, now: @now + 20, leeway: 30)
      assert {:ok, %Claims{}} = JWT.verify(client(), token, now: @now)
    end

    test "rejects a token with no exp at all" do
      token = hs256(claims() |> Map.delete("exp"))

      assert {:error, :missing_exp} = JWT.verify(client(), token, now: @now)
    end

    test "rejects a token that is not yet valid" do
      token = hs256(claims(%{"nbf" => @now + 60}))

      assert {:error, :token_not_yet_valid} = JWT.verify(client(), token, now: @now)
      assert {:ok, %Claims{}} = JWT.verify(client(), token, now: @now + 61)
    end

    test "explains how to configure :jwt_secret when it is missing" do
      token = hs256(claims())

      assert {:error, %Error.Configuration{} = error} =
               JWT.verify(client(jwt_secret: nil), token, now: @now)

      message = Exception.message(error)
      assert message =~ ":jwt_secret"
      assert message =~ "HS256"
    end

    test "defaults :now to the wall clock" do
      assert {:error, :token_expired} = JWT.verify(client(), hs256(claims(%{"exp" => 1})))
    end
  end

  describe "issuer and audience validation" do
    test "are skipped unless the caller supplies them" do
      token = hs256(claims(%{"iss" => "https://other.supabase.co/auth/v1", "aud" => "anon"}))

      assert {:ok, %Claims{}} = JWT.verify(client(), token, now: @now)
    end

    test "accept a match and a list of alternatives" do
      token = hs256(claims())

      assert {:ok, %Claims{}} =
               JWT.verify(client(), token, now: @now, issuer: @issuer, audience: "authenticated")

      assert {:ok, %Claims{}} =
               JWT.verify(client(), token,
                 now: @now,
                 issuer: ["https://other.supabase.co/auth/v1", @issuer],
                 audience: ["authenticated", "anon"]
               )
    end

    test "reject a token minted by another project" do
      token = hs256(claims(%{"iss" => "https://other.supabase.co/auth/v1"}))

      assert {:error, {:invalid_issuer, "https://other.supabase.co/auth/v1"}} =
               JWT.verify(client(), token, now: @now, issuer: @issuer)
    end

    test "reject a wrong audience, including the list form" do
      token = hs256(claims(%{"aud" => "anon"}))

      assert {:error, {:invalid_audience, "anon"}} =
               JWT.verify(client(), token, now: @now, audience: "authenticated")

      token = hs256(claims(%{"aud" => ["anon", "authenticated"]}))
      assert {:ok, %Claims{}} = JWT.verify(client(), token, now: @now, audience: "authenticated")
    end
  end

  describe "asymmetric signing keys via JWKS" do
    test "selects the key named by the token's kid and reports the endpoint it read" do
      other = ec_key("other-kid")
      signing = ec_key("signing-kid")
      capture = stub_jwks([public(other), public(signing)])

      token = es256(claims(), signing)

      assert {:ok, %Claims{sub: "123e4567-e89b-12d3-a456-426614174000"}} =
               JWT.verify(client(jwt_secret: nil), token, now: @now)

      conn = capture.()
      assert conn.method == "GET"
      assert conn.request_path == "/auth/v1/.well-known/jwks.json"
    end

    test "verifies without a kid when the project publishes exactly one key" do
      signing = ec_key("only-kid")
      stub_jwks([public(signing)])

      token = sign(claims(), Joken.Signer.create("ES256", signing.private))

      assert {:ok, %Claims{}} = JWT.verify(client(jwt_secret: nil), token, now: @now)
    end

    test "rejects a token signed by a key that is not the published one" do
      stub_jwks([public(ec_key("published-kid"))])

      token = es256(claims(), ec_key("published-kid"))

      assert {:error, :signature_error} = JWT.verify(client(jwt_secret: nil), token, now: @now)
    end

    test "never falls back to the shared secret for an asymmetric token" do
      stub_jwks([])

      token = es256(claims(), ec_key("kid"))

      assert {:error, %Error.Configuration{}} = JWT.verify(client(), token, now: @now)
    end

    test "explains an empty key set as an HS256-only project" do
      stub_jwks([])

      token = es256(claims(), ec_key("kid"))

      assert {:error, %Error.Configuration{} = error} =
               JWT.verify(client(jwt_secret: nil), token, now: @now)

      message = Exception.message(error)
      assert message =~ "jwt_secret"
      assert message =~ "no keys"
    end

    test "refuses a published key whose alg contradicts the token header" do
      signing = ec_key("kid")
      stub_jwks([signing |> public() |> Map.put("alg", "RS256")])

      token = es256(claims(), signing)

      assert {:error, {:algorithm_mismatch, "ES256", "RS256"}} =
               JWT.verify(client(jwt_secret: nil), token, now: @now)
    end

    test "surfaces a failure to read the JWKS endpoint" do
      Req.Test.stub(AshSupabase.Test.Client, &Req.Test.transport_error(&1, :econnrefused))

      token = es256(claims(), ec_key("kid"))

      assert {:error, %Error.Transport{}} = JWT.verify(client(jwt_secret: nil), token, now: @now)
    end
  end

  describe "key rotation" do
    test "refreshes once on an unknown kid and then verifies with the new key" do
      old = ec_key("old-kid")
      new = ec_key("new-kid")
      counter = stub_sequence([[public(old)], [public(old), public(new)]])
      start_supervised!(JWKS)

      # Warm the cache with the pre-rotation key set.
      assert {:ok, [_key]} = JWKS.fetch(client(), jwks_url: rotation_url())

      token = es256(claims(), new)

      assert {:ok, %Claims{}} =
               JWT.verify(client(jwt_secret: nil), token, now: @now, jwks_url: rotation_url())

      assert counter.() == 2
    end

    test "gives up after one refresh when the kid is still unknown" do
      stub_jwks([public(ec_key("known-kid"))])

      token = es256(claims(), ec_key("stranger-kid"))

      assert {:error, {:unknown_kid, "stranger-kid"}} =
               JWT.verify(client(jwt_secret: nil), token, now: @now)
    end
  end

  describe "AshSupabase.Auth.JWKS caching" do
    test "serves a second verification from ETS without a second request" do
      signing = ec_key("cached-kid")
      counter = stub_sequence([[public(signing)]], repeat_last: true)
      start_supervised!(JWKS)

      token = es256(claims(), signing)

      assert {:ok, %Claims{}} = JWT.verify(client(jwt_secret: nil), token, now: @now)
      assert {:ok, %Claims{}} = JWT.verify(client(jwt_secret: nil), token, now: @now)
      assert counter.() == 1
    end

    test "honors the endpoint's Cache-Control max-age, and :ttl overrides it" do
      keys = [public(ec_key("kid"))]

      counter =
        stub_responses(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("cache-control", "public, max-age=600")
          |> Req.Test.json(%{"keys" => keys})
        end)

      start_supervised!(JWKS)

      assert {:ok, ^keys} = JWKS.fetch(client())
      assert {:ok, ^keys} = JWKS.fetch(client())
      assert counter.() == 1

      # A zero TTL makes every entry stale on write.
      JWKS.clear()
      assert {:ok, ^keys} = JWKS.fetch(client(), ttl: 0)
      assert {:ok, ^keys} = JWKS.fetch(client(), ttl: 0)
      assert counter.() == 3
    end

    test "does not cache a response that forbids it with max-age=0" do
      keys = [public(ec_key("kid"))]

      counter =
        stub_responses(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("cache-control", "max-age=0, private, must-revalidate")
          |> Req.Test.json(%{"keys" => keys})
        end)

      start_supervised!(JWKS)

      assert {:ok, ^keys} = JWKS.fetch(client())
      assert {:ok, ^keys} = JWKS.fetch(client())
      assert counter.() == 2
    end

    test "refresh/2 ignores a warm cache" do
      keys = [public(ec_key("kid"))]
      counter = stub_responses(&Req.Test.json(&1, %{"keys" => keys}))
      start_supervised!(JWKS)

      assert {:ok, ^keys} = JWKS.fetch(client())
      assert {:ok, ^keys} = JWKS.refresh(client())
      assert counter.() == 2
    end

    test "falls back to a direct fetch when the cache process is not running" do
      refute Process.whereis(JWKS)

      keys = [public(ec_key("kid"))]
      counter = stub_responses(&Req.Test.json(&1, %{"keys" => keys}))

      assert {:ok, ^keys} = JWKS.fetch(client())
      assert {:ok, ^keys} = JWKS.fetch(client())
      assert counter.() == 2
    end

    test "reports a JWKS body without a keys list as a request error" do
      Req.Test.stub(AshSupabase.Test.Client, &Req.Test.json(&1, %{"unexpected" => true}))

      assert {:error, %Error.Request{status: 200}} = JWKS.fetch(client())
    end

    test "find_key/2 selects by kid and refuses to guess" do
      a = %{"kid" => "a"}
      b = %{"kid" => "b"}

      assert JWKS.find_key([a, b], "b") == b
      assert JWKS.find_key([a, b], "missing") == nil
      assert JWKS.find_key([a, b], nil) == nil
      assert JWKS.find_key([a], nil) == a
      assert JWKS.find_key([], nil) == nil
    end

    test "jwks_url/1 defaults to the project's well-known endpoint" do
      assert {:ok, "https://test.supabase.co/auth/v1/.well-known/jwks.json"} =
               JWKS.jwks_url(client())
    end
  end

  describe "peek_claims/1 and peek_header/1" do
    test "decode without verifying anything" do
      token = hs256(claims())

      assert {:ok, header} = JWT.peek_header(token)
      assert header["alg"] == "HS256"
      assert header["typ"] == "JWT"

      assert {:ok, peeked} = JWT.peek_claims(token)
      assert peeked["sub"] == "123e4567-e89b-12d3-a456-426614174000"
    end

    test "decode a token whose signature is worthless" do
      [header, payload, _signature] = String.split(hs256(claims()), ".")
      forged = header <> "." <> payload <> ".not-a-signature"

      assert {:ok, %{"sub" => "123e4567-e89b-12d3-a456-426614174000"}} =
               JWT.peek_claims(forged)

      assert {:error, :signature_error} = JWT.verify(client(), forged, now: @now)
    end

    test "surface a malformed token instead of raising" do
      assert {:error, :token_malformed} = JWT.peek_claims("nonsense")
      assert {:error, :token_malformed} = JWT.peek_header("nonsense")
      assert {:error, :token_malformed} = JWT.verify(client(), "nonsense", now: @now)
    end

    test "reads the kid a signed token carries" do
      key = ec_key("some-kid")

      assert {:ok, %{"kid" => "some-kid", "alg" => "ES256"}} =
               JWT.peek_header(es256(claims(), key))
    end
  end

  defp client(opts \\ []) do
    Keyword.merge(
      [
        url: "https://test.supabase.co",
        api_key: "test-anon-key",
        jwt_secret: @secret,
        req_options: @req_options
      ],
      opts
    )
  end

  defp rotation_url, do: "https://test.supabase.co/auth/v1/.well-known/rotation.json"

  defp claims(overrides \\ %{}) do
    Map.merge(
      %{
        "iss" => @issuer,
        "sub" => "123e4567-e89b-12d3-a456-426614174000",
        "aud" => "authenticated",
        "exp" => @now + 3600,
        "iat" => @now,
        "email" => "user@example.com",
        "phone" => "",
        "app_metadata" => %{"provider" => "email"},
        "user_metadata" => %{"full_name" => "Ada"},
        "role" => "authenticated",
        "aal" => "aal1",
        "amr" => [%{"method" => "password", "timestamp" => @now}],
        "session_id" => "9f8e7d6c-5b4a-3210-fedc-ba9876543210",
        "is_anonymous" => false
      },
      overrides
    )
  end

  defp hs256(claims), do: sign(claims, Joken.Signer.create("HS256", @secret))

  defp es256(claims, key),
    do: sign(claims, Joken.Signer.create("ES256", key.private, %{"kid" => key.kid}))

  defp sign(claims, signer) do
    {:ok, token} = Joken.Signer.sign(claims, signer)
    token
  end

  # A real P-256 key pair per test, so nothing is verified against a fixture
  # that could have been copied from the implementation.
  defp ec_key(kid) do
    jwk = JOSE.JWK.generate_key({:ec, "P-256"})
    {_type, private} = JOSE.JWK.to_map(jwk)
    {_type, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()

    %{kid: kid, private: private, public: public}
  end

  defp public(key) do
    Map.merge(key.public, %{
      "kid" => key.kid,
      "alg" => "ES256",
      "use" => "sig",
      "key_ops" => ["verify"]
    })
  end

  defp stub_jwks(keys) do
    parent = self()
    ref = make_ref()

    Req.Test.stub(AshSupabase.Test.Client, fn conn ->
      send(parent, {ref, conn})
      Req.Test.json(conn, %{"keys" => keys})
    end)

    fn ->
      receive do
        {^ref, conn} -> conn
      after
        1_000 -> flunk("the JWKS endpoint was never read")
      end
    end
  end

  # Stubs a fixed response and returns a function yielding the request count.
  defp stub_responses(responder) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(AshSupabase.Test.Client, fn conn ->
      Agent.update(counter, &(&1 + 1))
      responder.(conn)
    end)

    fn -> Agent.get(counter, & &1) end
  end

  # Serves each key set in turn, so a rotation can be observed request by request.
  defp stub_sequence(key_sets, opts \\ []) do
    {:ok, state} = Agent.start_link(fn -> {key_sets, 0} end)

    Req.Test.stub(AshSupabase.Test.Client, fn conn ->
      keys =
        Agent.get_and_update(state, fn
          {[keys], count} -> {keys, {if(opts[:repeat_last], do: [keys], else: []), count + 1}}
          {[keys | rest], count} -> {keys, {rest, count + 1}}
          {[], count} -> {[], {[], count + 1}}
        end)

      conn
      |> Plug.Conn.put_resp_header("cache-control", "public, max-age=600")
      |> Req.Test.json(%{"keys" => keys})
    end)

    fn -> Agent.get(state, fn {_remaining, count} -> count end) end
  end
end
