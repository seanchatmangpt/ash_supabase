defmodule AshSupabase.AuthTest do
  use AshSupabase.Case, async: true

  alias AshSupabase.Auth
  alias AshSupabase.Auth.Admin
  alias AshSupabase.Auth.Identity
  alias AshSupabase.Auth.Session
  alias AshSupabase.Auth.User
  alias AshSupabase.Error

  doctest AshSupabase.Auth
  doctest AshSupabase.Auth.User
  doctest AshSupabase.Auth.Identity
  doctest AshSupabase.Auth.Session

  @user %{
    "id" => "123e4567-e89b-12d3-a456-426614174000",
    "aud" => "authenticated",
    "role" => "authenticated",
    "email" => "user@example.com",
    "email_confirmed_at" => "2026-09-06T12:00:00Z",
    "phone" => "",
    "phone_confirmed_at" => nil,
    "confirmed_at" => "2026-09-06T12:00:00Z",
    "last_sign_in_at" => "2026-09-06T12:00:00Z",
    "app_metadata" => %{"provider" => "email", "providers" => ["email"]},
    "user_metadata" => %{"full_name" => "Ada"},
    "factors" => [
      %{
        "id" => "f1",
        "status" => "verified",
        "factor_type" => "totp",
        "friendly_name" => "phone",
        "created_at" => "2026-09-06T11:00:00Z",
        "last_challenged_at" => nil
      }
    ],
    "identities" => [
      %{
        "identity_id" => "0f6a",
        "id" => "123e4567-e89b-12d3-a456-426614174000",
        "user_id" => "123e4567-e89b-12d3-a456-426614174000",
        "identity_data" => %{"email" => "user@example.com"},
        "provider" => "email",
        "last_sign_in_at" => "2026-09-06T12:00:00Z",
        "created_at" => "2026-09-06T11:59:00Z",
        "updated_at" => "2026-09-06T11:59:00Z",
        "email" => "user@example.com"
      }
    ],
    "banned_until" => nil,
    "created_at" => "2021-02-17T04:43:32.770206+00:00",
    "updated_at" => "2026-09-06T12:00:00Z",
    "deleted_at" => nil,
    "is_anonymous" => false
  }

  @session %{
    "access_token" => "eyJhbGciOiJFUzI1NiJ9.access",
    "token_type" => "bearer",
    "expires_in" => 3600,
    "expires_at" => 1_757_753_066,
    "refresh_token" => "4nYUCw0wZR_DNOTSDbSGMQ",
    "user" => @user
  }

  describe "sign_up/2" do
    test "posts to /auth/v1/signup and returns a session when confirmation is disabled" do
      capture = expect_request(&Req.Test.json(&1, @session))

      assert {:ok, %Session{} = session} =
               Auth.sign_up(TestClient,
                 email: "user@example.com",
                 password: "hunter2",
                 data: %{"full_name" => "Ada"}
               )

      conn = capture.()
      assert conn.method == "POST"
      assert conn.request_path == "/auth/v1/signup"
      assert conn.query_string == ""

      assert request_body(conn) == %{
               "email" => "user@example.com",
               "password" => "hunter2",
               "data" => %{"full_name" => "Ada"}
             }

      assert header(conn, "apikey") == "test-anon-key"
      assert session.access_token == "eyJhbGciOiJFUzI1NiJ9.access"
      assert session.user.email == "user@example.com"
    end

    test "returns a bare user when a confirmation step is pending" do
      capture = expect_request(&Req.Test.json(&1, @user))

      assert {:ok, %User{} = user} =
               Auth.sign_up(TestClient, %{"email" => "user@example.com", "password" => "hunter2"})

      assert capture.().request_path == "/auth/v1/signup"
      assert user.id == "123e4567-e89b-12d3-a456-426614174000"
    end

    test "drops nil values and lifts :captcha_token into gotrue_meta_security" do
      capture = expect_request(&Req.Test.json(&1, @session))

      assert {:ok, %Session{}} =
               Auth.sign_up(TestClient,
                 email: "user@example.com",
                 password: "hunter2",
                 phone: nil,
                 captcha_token: "captcha-response"
               )

      assert request_body(capture.()) == %{
               "email" => "user@example.com",
               "password" => "hunter2",
               "gotrue_meta_security" => %{"captcha_token" => "captcha-response"}
             }
    end
  end

  describe "sign_in_with_password/2" do
    test "sends grant_type as a query parameter, not in the body" do
      capture = expect_request(&Req.Test.json(&1, @session))

      assert {:ok, %Session{} = session} =
               Auth.sign_in_with_password(TestClient,
                 email: "user@example.com",
                 password: "hunter2"
               )

      conn = capture.()
      assert conn.method == "POST"
      assert conn.request_path == "/auth/v1/token"
      assert conn.query_string == "grant_type=password"
      assert query_params(conn) == [{"grant_type", "password"}]
      assert request_body(conn) == %{"email" => "user@example.com", "password" => "hunter2"}
      assert session.token_type == "bearer"
      assert session.expires_at == ~U[2025-09-13 08:44:26Z]
    end

    test "decodes the weak_password advisory" do
      body =
        Map.put(@session, "weak_password", %{"reasons" => ["length"], "message" => "too weak"})

      expect_request(&Req.Test.json(&1, body))

      assert {:ok, %Session{weak_password: %{"reasons" => ["length"]}}} =
               Auth.sign_in_with_password(TestClient, email: "a@b.co", password: "x")
    end

    test "returns a request error carrying the GoTrue error code" do
      expect_request(fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "code" => 400,
          "error_code" => "invalid_credentials",
          "msg" => "Invalid login credentials"
        })
      end)

      assert {:error, %Error.Request{} = error} =
               Auth.sign_in_with_password(TestClient, email: "a@b.co", password: "nope")

      assert error.status == 400
      assert error.code == "invalid_credentials"
      assert error.supabase_message == "Invalid login credentials"
      assert Exception.message(error) =~ "invalid_credentials"
    end

    test "returns a transport error when the request never completes" do
      expect_request(&Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Error.Transport{reason: reason}} =
               Auth.sign_in_with_password(TestClient, email: "a@b.co", password: "x")

      assert %Req.TransportError{reason: :econnrefused} = reason
    end
  end

  describe "the other /token grants" do
    test "sign_in_with_id_token/2 uses grant_type=id_token" do
      capture = expect_request(&Req.Test.json(&1, @session))

      assert {:ok, %Session{}} =
               Auth.sign_in_with_id_token(TestClient,
                 provider: "google",
                 id_token: "google-id-token",
                 nonce: "n"
               )

      conn = capture.()
      assert conn.query_string == "grant_type=id_token"

      assert request_body(conn) == %{
               "provider" => "google",
               "id_token" => "google-id-token",
               "nonce" => "n"
             }
    end

    test "refresh_session/2 accepts a bare refresh token" do
      capture = expect_request(&Req.Test.json(&1, @session))

      assert {:ok, %Session{}} = Auth.refresh_session(TestClient, "4nYUCw0wZR_DNOTSDbSGMQ")

      conn = capture.()
      assert conn.request_path == "/auth/v1/token"
      assert conn.query_string == "grant_type=refresh_token"
      assert request_body(conn) == %{"refresh_token" => "4nYUCw0wZR_DNOTSDbSGMQ"}
    end

    test "exchange_code_for_session/2 uses grant_type=pkce" do
      capture = expect_request(&Req.Test.json(&1, @session))

      assert {:ok, %Session{}} =
               Auth.exchange_code_for_session(TestClient, auth_code: "code", code_verifier: "v")

      conn = capture.()
      assert conn.query_string == "grant_type=pkce"
      assert request_body(conn) == %{"auth_code" => "code", "code_verifier" => "v"}
    end
  end

  describe "sign_in_with_otp/2 and verify_otp/2" do
    test "posts to /auth/v1/otp and returns the raw body" do
      capture = expect_request(&Req.Test.json(&1, %{}))

      assert {:ok, %{}} = Auth.sign_in_with_otp(TestClient, email: "user@example.com")

      conn = capture.()
      assert conn.request_path == "/auth/v1/otp"
      assert request_body(conn) == %{"email" => "user@example.com"}
    end

    test "returns the message id for an SMS OTP" do
      capture = expect_request(&Req.Test.json(&1, %{"message_id" => "sm-1"}))

      assert {:ok, %{"message_id" => "sm-1"}} =
               Auth.sign_in_with_otp(TestClient, phone: "+15551234567", channel: "whatsapp")

      assert request_body(capture.()) == %{"phone" => "+15551234567", "channel" => "whatsapp"}
    end

    test "verify_otp/2 posts token_hash to /auth/v1/verify" do
      capture = expect_request(&Req.Test.json(&1, @session))

      assert {:ok, %Session{} = session} =
               Auth.verify_otp(TestClient, type: "magiclink", token_hash: "hash")

      conn = capture.()
      assert conn.method == "POST"
      assert conn.request_path == "/auth/v1/verify"
      assert request_body(conn) == %{"type" => "magiclink", "token_hash" => "hash"}
      assert session.refresh_token == "4nYUCw0wZR_DNOTSDbSGMQ"
    end
  end

  describe "sign_out/3" do
    test "posts the user's token to /auth/v1/logout and returns :ok on 204" do
      capture = expect_request(&Plug.Conn.send_resp(&1, 204, ""))

      assert :ok = Auth.sign_out(TestClient, "user-access-token")

      conn = capture.()
      assert conn.method == "POST"
      assert conn.request_path == "/auth/v1/logout"
      assert conn.query_string == ""
      assert header(conn, "authorization") == "Bearer user-access-token"
    end

    test "passes :scope as a query parameter" do
      capture = expect_request(&Plug.Conn.send_resp(&1, 204, ""))

      assert :ok = Auth.sign_out(TestClient, "user-access-token", scope: :others)
      assert capture.().query_string == "scope=others"
    end

    test "surfaces a 401" do
      expect_request(fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"code" => 401, "error_code" => "no_authorization", "msg" => "nope"})
      end)

      assert {:error, %Error.Request{status: 401, code: "no_authorization"}} =
               Auth.sign_out(TestClient, "stale")
    end
  end

  describe "get_user/2 and update_user/3" do
    test "get_user/2 authenticates as the user" do
      capture = expect_request(&Req.Test.json(&1, @user))

      assert {:ok, %User{} = user} = Auth.get_user(TestClient, "user-access-token")

      conn = capture.()
      assert conn.method == "GET"
      assert conn.request_path == "/auth/v1/user"
      assert header(conn, "authorization") == "Bearer user-access-token"
      assert header(conn, "apikey") == "test-anon-key"
      assert user.app_metadata == %{"provider" => "email", "providers" => ["email"]}
    end

    test "update_user/3 uses PUT" do
      capture = expect_request(&Req.Test.json(&1, @user))

      assert {:ok, %User{}} =
               Auth.update_user(TestClient, "user-access-token",
                 password: "new-password",
                 data: %{"full_name" => "Ada L"}
               )

      conn = capture.()
      assert conn.method == "PUT"
      assert conn.request_path == "/auth/v1/user"
      assert header(conn, "authorization") == "Bearer user-access-token"

      assert request_body(conn) == %{
               "password" => "new-password",
               "data" => %{"full_name" => "Ada L"}
             }
    end
  end

  describe "reset_password_for_email/3, resend/2, reauthenticate/2" do
    test "reset_password_for_email/3 posts to /auth/v1/recover and returns :ok" do
      capture = expect_request(&Req.Test.json(&1, %{}))

      assert :ok =
               Auth.reset_password_for_email(TestClient, "user@example.com",
                 redirect_to: "https://example.com/reset"
               )

      conn = capture.()
      assert conn.request_path == "/auth/v1/recover"

      assert request_body(conn) == %{
               "email" => "user@example.com",
               "redirect_to" => "https://example.com/reset"
             }
    end

    test "resend/2 posts to /auth/v1/resend" do
      capture = expect_request(&Req.Test.json(&1, %{"message_id" => "m-1"}))

      assert {:ok, %{"message_id" => "m-1"}} =
               Auth.resend(TestClient, type: "signup", email: "user@example.com")

      conn = capture.()
      assert conn.request_path == "/auth/v1/resend"
      assert request_body(conn) == %{"type" => "signup", "email" => "user@example.com"}
    end

    test "reauthenticate/2 posts the user's token" do
      capture = expect_request(&Req.Test.json(&1, %{}))

      assert :ok = Auth.reauthenticate(TestClient, "user-access-token")

      conn = capture.()
      assert conn.request_path == "/auth/v1/reauthenticate"
      assert header(conn, "authorization") == "Bearer user-access-token"
    end
  end

  describe "sign_in_anonymously/2" do
    test "posts to /auth/v1/signup with no credentials" do
      capture = expect_request(&Req.Test.json(&1, @session))

      assert {:ok, %Session{}} = Auth.sign_in_anonymously(TestClient)

      conn = capture.()
      assert conn.request_path == "/auth/v1/signup"
      assert request_body(conn) == nil or request_body(conn) == %{}
    end

    test "forwards :data as user metadata" do
      capture = expect_request(&Req.Test.json(&1, @session))

      assert {:ok, %Session{}} = Auth.sign_in_anonymously(TestClient, data: %{"guest" => true})
      assert request_body(capture.()) == %{"data" => %{"guest" => true}}
    end
  end

  describe "authorize_url/3" do
    test "builds the provider redirect without making a request" do
      assert {:ok, url} =
               Auth.authorize_url(TestClient, :google,
                 scopes: ["email", "profile"],
                 redirect_to: "https://example.com/callback",
                 code_challenge: "abc",
                 code_challenge_method: "s256"
               )

      uri = URI.parse(url)
      assert uri.host == "test.supabase.co"
      assert uri.path == "/auth/v1/authorize"

      assert URI.decode_query(uri.query) == %{
               "provider" => "google",
               "scopes" => "email profile",
               "redirect_to" => "https://example.com/callback",
               "code_challenge" => "abc",
               "code_challenge_method" => "s256"
             }
    end

    test "omits absent options and appends :query_params" do
      assert {:ok, url} =
               Auth.authorize_url(TestClient, "github", query_params: [prompt: "consent"])

      assert url == "https://test.supabase.co/auth/v1/authorize?provider=github&prompt=consent"
    end

    test "errors on an unresolvable client instead of raising" do
      assert {:error, %Error.Configuration{}} = Auth.authorize_url(NotAClientModule, :google)
      assert Auth.authorize_url!(TestClient, :google) =~ "provider=google"
    end
  end

  describe "settings/1" do
    test "reads the project's public auth settings" do
      capture = expect_request(&Req.Test.json(&1, %{"external" => %{"google" => true}}))

      assert {:ok, %{"external" => %{"google" => true}}} = Auth.settings(TestClient)
      assert capture.().request_path == "/auth/v1/settings"
    end
  end

  describe "AshSupabase.Auth.User" do
    test "decodes every documented field, including nested identities and factors" do
      user = User.from_json(@user)

      assert user.id == "123e4567-e89b-12d3-a456-426614174000"
      assert user.aud == "authenticated"
      assert user.role == "authenticated"
      assert user.email_confirmed_at == ~U[2026-09-06 12:00:00Z]
      assert user.phone == ""
      assert user.phone_confirmed_at == nil
      assert user.confirmed_at == ~U[2026-09-06 12:00:00Z]
      assert user.last_sign_in_at == ~U[2026-09-06 12:00:00Z]
      assert user.created_at == ~U[2021-02-17 04:43:32.770206Z]
      assert user.is_anonymous == false
      assert [%Identity{provider: "email"} = identity] = user.identities
      assert identity.created_at == ~U[2026-09-06 11:59:00Z]
      assert [%AshSupabase.Auth.Factor{factor_type: "totp", status: "verified"}] = user.factors
    end

    test "tolerates missing keys and unparseable timestamps" do
      user = User.from_json(%{"id" => "u1", "created_at" => "not a timestamp"})

      assert user.id == "u1"
      assert user.created_at == "not a timestamp"
      assert user.email == nil
      assert user.app_metadata == %{}
      assert user.user_metadata == %{}
      assert user.identities == []
      assert user.factors == []
      assert user.is_anonymous == false
    end

    test "banned?/2 respects an elapsed ban and identity/2 finds a provider" do
      user = User.from_json(Map.put(@user, "banned_until", "2026-09-07T00:00:00Z"))

      assert User.banned?(user, ~U[2026-09-06 12:00:00Z])
      refute User.banned?(user, ~U[2026-09-08 00:00:00Z])
      refute User.banned?(User.from_json(@user), ~U[2026-09-06 12:00:00Z])

      assert %Identity{provider: "email"} = User.identity(user, "email")
      assert User.identity(user, "google") == nil
    end
  end

  describe "AshSupabase.Auth.Session" do
    test "converts expires_at from unix seconds and nests the user" do
      session = Session.from_json(@session)

      assert session.expires_in == 3600
      assert session.expires_at == ~U[2025-09-13 08:44:26Z]
      assert %User{email: "user@example.com"} = session.user
      assert session.provider_token == nil
    end

    test "expired?/2 and expires_in_seconds/2" do
      session = Session.from_json(@session)

      refute Session.expired?(session, ~U[2025-09-13 08:00:00Z])
      assert Session.expired?(session, ~U[2025-09-13 09:00:00Z])
      assert Session.expired?(session, ~U[2025-09-13 08:44:26Z])
      assert Session.expires_in_seconds(session, ~U[2025-09-13 08:44:16Z]) == 10
      assert Session.expires_in_seconds(session, ~U[2025-09-13 09:00:00Z]) == 0

      assert Session.expired?(%Session{}, ~U[2025-09-13 08:00:00Z])
      assert Session.expires_in_seconds(%Session{}, ~U[2025-09-13 08:00:00Z]) == nil
    end

    test "redacts every token when inspected" do
      session =
        Session.from_json(
          Map.merge(@session, %{
            "provider_token" => "ya29.provider",
            "provider_refresh_token" => "1//refresh"
          })
        )

      inspected = inspect(session)

      refute inspected =~ "eyJhbGciOiJFUzI1NiJ9.access"
      refute inspected =~ "4nYUCw0wZR_DNOTSDbSGMQ"
      refute inspected =~ "ya29.provider"
      refute inspected =~ "1//refresh"
      assert inspected =~ "[REDACTED]"
      assert inspected =~ "AshSupabase.Auth.Session"
    end
  end

  describe "AshSupabase.Auth.Admin" do
    test "list_users/2 sends page and per_page and reads x-total-count" do
      capture =
        expect_request(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("x-total-count", "137")
          |> Req.Test.json(%{"users" => [@user], "aud" => "authenticated"})
        end)

      assert {:ok, %{users: [%User{}], aud: "authenticated", total: 137}} =
               Admin.list_users(TestClient, page: 2, per_page: 50)

      conn = capture.()
      assert conn.method == "GET"
      assert conn.request_path == "/auth/v1/admin/users"
      assert query_params(conn) == [{"page", "2"}, {"per_page", "50"}]
    end

    test "get_user_by_id/2, create_user/2 and update_user_by_id/3 hit /admin/users" do
      capture = expect_request(&Req.Test.json(&1, @user))
      assert {:ok, %User{}} = Admin.get_user_by_id(TestClient, "123e4567")
      assert capture.().request_path == "/auth/v1/admin/users/123e4567"

      capture = expect_request(&Req.Test.json(&1, @user))

      assert {:ok, %User{}} =
               Admin.create_user(TestClient,
                 email: "user@example.com",
                 email_confirm: true,
                 app_metadata: %{"tenant" => "acme"}
               )

      conn = capture.()
      assert conn.method == "POST"
      assert conn.request_path == "/auth/v1/admin/users"

      assert request_body(conn) == %{
               "email" => "user@example.com",
               "email_confirm" => true,
               "app_metadata" => %{"tenant" => "acme"}
             }

      capture = expect_request(&Req.Test.json(&1, @user))
      assert {:ok, %User{}} = Admin.update_user_by_id(TestClient, "u1", ban_duration: "24h")

      conn = capture.()
      assert conn.method == "PUT"
      assert conn.request_path == "/auth/v1/admin/users/u1"
      assert request_body(conn) == %{"ban_duration" => "24h"}
    end

    test "delete_user/3 sends should_soft_delete" do
      capture = expect_request(&Req.Test.json(&1, %{}))

      assert {:ok, nil} = Admin.delete_user(TestClient, "u1", should_soft_delete: true)

      conn = capture.()
      assert conn.method == "DELETE"
      assert conn.request_path == "/auth/v1/admin/users/u1"
      assert request_body(conn) == %{"should_soft_delete" => true}

      capture = expect_request(&Req.Test.json(&1, @user))
      assert {:ok, %User{}} = Admin.delete_user(TestClient, "u1")
      assert request_body(capture.()) == %{"should_soft_delete" => false}
    end

    test "invite_user_by_email/3 posts to /auth/v1/invite" do
      capture = expect_request(&Req.Test.json(&1, @user))

      assert {:ok, %User{}} =
               Admin.invite_user_by_email(TestClient, "new@example.com", data: %{"team" => "a"})

      conn = capture.()
      assert conn.request_path == "/auth/v1/invite"
      assert request_body(conn) == %{"email" => "new@example.com", "data" => %{"team" => "a"}}
    end

    test "generate_link/2 splits the response into user and properties" do
      body =
        Map.merge(@user, %{
          "action_link" => "https://test.supabase.co/auth/v1/verify?token=hash&type=magiclink",
          "email_otp" => "123456",
          "hashed_token" => "hash",
          "verification_type" => "magiclink",
          "redirect_to" => "https://example.com"
        })

      capture = expect_request(&Req.Test.json(&1, body))

      assert {:ok, %{user: %User{} = user, properties: properties}} =
               Admin.generate_link(TestClient, type: "magiclink", email: "user@example.com")

      conn = capture.()
      assert conn.method == "POST"
      assert conn.request_path == "/auth/v1/admin/generate_link"
      assert request_body(conn) == %{"type" => "magiclink", "email" => "user@example.com"}

      assert user.email == "user@example.com"
      assert properties["email_otp"] == "123456"
      assert properties["hashed_token"] == "hash"
      assert properties["verification_type"] == "magiclink"
    end
  end
end
