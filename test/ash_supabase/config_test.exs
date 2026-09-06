defmodule AshSupabase.ConfigTest do
  use ExUnit.Case, async: true

  alias AshSupabase.Config

  doctest AshSupabase.Config

  describe "new/1" do
    test "requires a url and an api key" do
      assert {:error, message} = Config.new([])
      assert message =~ "required"

      assert {:error, message} = Config.new(api_key: "k")
      assert message =~ ":url"
    end

    test "defaults the bearer token to the api key" do
      assert {:ok, config} = Config.new(url: "https://x.supabase.co", api_key: "anon")
      assert config.access_token == "anon"
    end

    test "keeps an explicit access token" do
      assert {:ok, config} =
               Config.new(url: "https://x.supabase.co", api_key: "anon", access_token: "svc")

      assert config.access_token == "svc"
    end

    test "trims a trailing slash so paths do not double up" do
      assert {:ok, config} = Config.new(url: "https://x.supabase.co/", api_key: "k")
      assert config.url == "https://x.supabase.co"
      assert Config.rest_url(config) == "https://x.supabase.co/rest/v1"
    end

    test "derives the JWKS url from the project url" do
      assert {:ok, config} = Config.new(url: "https://x.supabase.co", api_key: "k")
      assert config.jwks_url == "https://x.supabase.co/auth/v1/.well-known/jwks.json"
    end

    test "accepts an explicit JWKS url" do
      assert {:ok, config} =
               Config.new(url: "https://x.supabase.co", api_key: "k", jwks_url: "https://y/jwks")

      assert config.jwks_url == "https://y/jwks"
    end

    test "downcases header names" do
      assert {:ok, config} =
               Config.new(url: "https://x.supabase.co", api_key: "k", headers: [{"X-Foo", "1"}])

      assert config.headers == [{"x-foo", "1"}]
    end

    test "accepts a map" do
      assert {:ok, _} = Config.new(%{url: "https://x.supabase.co", api_key: "k"})
    end
  end

  describe "service urls" do
    setup do
      {:ok, config: Config.new!(url: "https://x.supabase.co", api_key: "k")}
    end

    test "cover every Supabase service", %{config: config} do
      assert Config.rest_url(config) == "https://x.supabase.co/rest/v1"
      assert Config.auth_url(config) == "https://x.supabase.co/auth/v1"
      assert Config.storage_url(config) == "https://x.supabase.co/storage/v1"
      assert Config.functions_url(config) == "https://x.supabase.co/functions/v1"
      assert Config.realtime_url(config) == "wss://x.supabase.co/realtime/v1/websocket"
    end

    test "realtime downgrades to ws for a plain http project url" do
      config = Config.new!(url: "http://localhost:54321", api_key: "k")
      assert Config.realtime_url(config) == "ws://localhost:54321/realtime/v1/websocket"
    end
  end

  describe "with_token/2" do
    test "replaces the bearer token" do
      config = Config.new!(url: "https://x.supabase.co", api_key: "anon")
      assert Config.with_token(config, "jwt").access_token == "jwt"
    end

    test "a nil token leaves the config alone" do
      config = Config.new!(url: "https://x.supabase.co", api_key: "anon")
      assert Config.with_token(config, nil) == config
    end
  end

  describe "secret redaction" do
    test "inspect never reveals keys or secrets" do
      config =
        Config.new!(
          url: "https://x.supabase.co",
          api_key: "super-secret-anon-key",
          access_token: "super-secret-service-key",
          jwt_secret: "super-secret-jwt-secret"
        )

      output = inspect(config)

      refute output =~ "super-secret"
      assert output =~ "[REDACTED]"
      # The url is not a secret and stays visible, which is what makes the
      # redacted output useful in a crash report.
      assert output =~ "https://x.supabase.co"
    end
  end
end
