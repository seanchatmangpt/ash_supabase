defmodule AshSupabase.GatewayTest do
  @moduledoc """
  Proves `AshSupabase.Gateway` end to end over a real HTTP connection (a
  real `Bandit` server, a real `Req` client, a real signed JWT) against
  real Postgres -- exactly the shape of request a Supabase client
  actually sends (`supabase.functions.invoke("ash-gateway", {body:
  ...})` forwards, verbatim, to this exact endpoint), never a bare
  in-process `Plug.Conn` conjured by hand.
  """

  use ExUnit.Case, async: false

  alias AshSupabase.Test.Accounts.User
  alias AshSupabase.Test.Repo
  alias AshSupabase.Test.Todos.Todo

  @secret "gateway-test-jwt-secret"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)

    {:ok, pid} =
      Bandit.start_link(
        plug: {AshSupabase.Gateway, otp_app: :ash_supabase, jwt_secret: @secret},
        port: 0
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)

    %{base_url: "http://localhost:#{port}"}
  end

  describe "create" do
    test "a valid token creating its own todo succeeds and the row exists in Postgres", %{
      base_url: base_url
    } do
      user = create_user!()

      response =
        post(base_url,
          token: sign(user.id),
          body: %{
            resource: "todos",
            action: "create",
            params: %{title: "Buy milk", user_id: user.id}
          }
        )

      assert response.status == 200
      assert response.body["data"]["title"] == "Buy milk"
      assert response.body["data"]["user_id"] == user.id

      assert %Todo{title: "Buy milk"} = Repo.get(Todo, response.body["data"]["id"])
    end

    test "creating a todo for someone else is refused (403) and writes nothing", %{
      base_url: base_url
    } do
      me = create_user!()
      someone_else = create_user!()

      response =
        post(base_url,
          token: sign(me.id),
          body: %{
            resource: "todos",
            action: "create",
            params: %{title: "hijack", user_id: someone_else.id}
          }
        )

      assert response.status == 403
      assert response.body["error"]["type"] == "forbidden"
      assert Repo.aggregate(Todo, :count) == 0
    end

    test "no Authorization header is refused (401) before touching the database", %{
      base_url: base_url
    } do
      response =
        post(base_url,
          body: %{resource: "todos", action: "create", params: %{title: "x", user_id: "y"}}
        )

      assert response.status == 401
      assert response.body["error"]["type"] == "unauthenticated"
      assert Repo.aggregate(Todo, :count) == 0
    end

    test "an expired token is refused (401)", %{base_url: base_url} do
      user = create_user!()

      response =
        post(base_url,
          token: sign(user.id, exp: System.system_time(:second) - 3600),
          body: %{
            resource: "todos",
            action: "create",
            params: %{title: "x", user_id: user.id}
          }
        )

      assert response.status == 401
    end
  end

  describe "update" do
    test "the owner updating their own todo succeeds", %{base_url: base_url} do
      user = create_user!()
      todo = create_todo!(user, "Buy milk")

      response =
        post(base_url,
          token: sign(user.id),
          body: %{
            resource: "todos",
            action: "update",
            params: %{id: todo.id, title: "Buy oat milk"}
          }
        )

      assert response.status == 200
      assert response.body["data"]["title"] == "Buy oat milk"
      assert Repo.reload!(todo).title == "Buy oat milk"
    end

    test "another actor updating someone else's todo is refused, unchanged in Postgres", %{
      base_url: base_url
    } do
      owner = create_user!()
      other = create_user!()
      todo = create_todo!(owner, "private")

      response =
        post(base_url,
          token: sign(other.id),
          body: %{
            resource: "todos",
            action: "update",
            params: %{id: todo.id, title: "hijacked"}
          }
        )

      # Not 403: Ash's own read policy filters the record out from under
      # `other` before the update is even attempted (`Ash.get/3` sees no
      # match), so this comes back exactly like the record doesn't exist
      # -- 404, never confirming to `other` that it does.
      assert response.status == 404
      assert Repo.reload!(todo).title == "private"
    end

    test "a missing params.id is refused (422)", %{base_url: base_url} do
      user = create_user!()

      response =
        post(base_url,
          token: sign(user.id),
          body: %{
            resource: "todos",
            action: "update",
            params: %{title: "no id given"}
          }
        )

      assert response.status == 422
      assert response.body["error"]["type"] == "invalid"
    end
  end

  describe "destroy" do
    test "the owner destroying their own todo succeeds and the row is gone", %{
      base_url: base_url
    } do
      user = create_user!()
      todo = create_todo!(user, "Buy milk")

      response =
        post(base_url,
          token: sign(user.id),
          body: %{
            resource: "todos",
            action: "destroy",
            params: %{id: todo.id}
          }
        )

      assert response.status == 200
      refute Repo.get(Todo, todo.id)
    end
  end

  describe "unexposed / unknown routes" do
    test "an unknown resource name is a 404", %{base_url: base_url} do
      user = create_user!()

      response =
        post(base_url,
          token: sign(user.id),
          body: %{
            resource: "nonexistent_table",
            action: "create",
            params: %{}
          }
        )

      assert response.status == 404
    end

    test "a real Todo action that is NOT in gateway_actions (:complete) is a 404, not a 403", %{
      base_url: base_url
    } do
      user = create_user!()
      todo = create_todo!(user, "Buy milk")

      response =
        post(base_url,
          token: sign(user.id),
          body: %{
            resource: "todos",
            action: "complete",
            params: %{id: todo.id}
          }
        )

      assert response.status == 404
      refute Repo.reload!(todo).completed
    end
  end

  defp create_user! do
    User
    |> Ash.Changeset.for_create(:create, %{
      id: Ash.UUID.generate(),
      email: "u-#{Ash.UUID.generate()}@example.com"
    })
    |> Ash.create!()
  end

  defp create_todo!(user, title) do
    Todo
    |> Ash.Changeset.for_create(:create, %{title: title, user_id: user.id}, actor: user)
    |> Ash.create!()
  end

  defp post(base_url, opts) do
    headers =
      case opts[:token] do
        nil -> []
        token -> [{"authorization", "Bearer #{token}"}]
      end

    Req.post!(base_url, json: opts[:body], headers: headers)
  end

  defp sign(user_id, opts \\ []) do
    exp = Keyword.get(opts, :exp, System.system_time(:second) + 3600)

    claims = %{
      "sub" => user_id,
      "role" => "authenticated",
      "aud" => "authenticated",
      "exp" => exp
    }

    header = %{"alg" => "HS256", "typ" => "JWT"} |> Jason.encode!() |> b64()
    payload = claims |> Jason.encode!() |> b64()
    signing_input = "#{header}.#{payload}"
    signature = :crypto.mac(:hmac, :sha256, @secret, signing_input) |> b64()
    "#{signing_input}.#{signature}"
  end

  defp b64(binary), do: Base.url_encode64(binary, padding: false)
end
