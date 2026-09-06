defmodule AshSupabase.Auth.Admin do
  @moduledoc """
  Service-role operations on Supabase Auth users.

  Everything here needs the project's **secret (service role) key**, because
  every one of these calls acts on users other than the caller. That key
  bypasses Row Level Security entirely, so it belongs in server-side
  configuration and must never reach a browser or a mobile binary:

      # config/runtime.exs
      config :my_app, MyApp.Supabase.Admin,
        url: System.fetch_env!("SUPABASE_URL"),
        api_key: System.fetch_env!("SUPABASE_SERVICE_ROLE_KEY")

      defmodule MyApp.Supabase.Admin do
        use AshSupabase.Client, otp_app: :my_app
      end

  Keeping the admin client as a *separate* module from the anon-key client is
  the point: it makes "this code path runs with god rights" visible at the call
  site instead of hiding behind an option.

      {:ok, %{users: users}} = AshSupabase.Auth.Admin.list_users(MyApp.Supabase.Admin)

  These endpoints live under `/auth/v1/admin` (plus `/auth/v1/invite`) and are
  the same ones supabase-js exposes as `auth.admin.*`.
  """

  alias AshSupabase.Auth.User
  alias AshSupabase.Client
  alias AshSupabase.Config

  @typedoc "Anything `AshSupabase.Client` accepts as a client."
  @type client :: Client.t()

  @typedoc "Request parameters, as a keyword list or a map. `nil` values are dropped."
  @type params :: keyword() | map()

  @typedoc "An error from the API, the network, or the client configuration."
  @type error :: AshSupabase.Auth.error()

  @typedoc """
  One page of users.

  `total` comes from the `x-total-count` response header and is `nil` if the
  deployment did not send it.
  """
  @type page :: %{
          users: [User.t()],
          aud: String.t() | nil,
          total: non_neg_integer() | nil
        }

  @doc """
  Lists users, newest first.

  ## Options

    * `:page` - 1-based page number. Defaults to the server's first page.
    * `:per_page` - page size. GoTrue's default is 50 and it caps the value.

  Returns `%{users: [...], aud: _, total: _}`. There is no "all users" call:
  page until `users` comes back shorter than `:per_page`.
  """
  @spec list_users(client(), keyword()) :: {:ok, page()} | {:error, error()}
  def list_users(client, opts \\ []) do
    params =
      [{"page", opts[:page]}, {"per_page", opts[:per_page]}]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map(fn {key, value} -> {key, to_string(value)} end)

    with {:ok, %{body: body, headers: headers}} <-
           request(client, :get, "/admin/users", params: params) do
      body = map(body)

      {:ok,
       %{
         users: Enum.map(body["users"] || [], &User.from_json/1),
         aud: body["aud"],
         total: total_count(headers)
       }}
    end
  end

  @doc """
  Fetches one user by id, without needing their access token.
  """
  @spec get_user_by_id(client(), String.t()) :: {:ok, User.t()} | {:error, error()}
  def get_user_by_id(client, id) when is_binary(id) do
    with {:ok, %{body: body}} <- request(client, :get, "/admin/users/" <> encode(id)) do
      {:ok, User.from_json(map(body))}
    end
  end

  @doc """
  Creates a user directly, with no email or SMS sent.

  Body keys: `email`, `phone`, `password`, `email_confirm`, `phone_confirm`,
  `user_metadata`, `app_metadata`, `role`, `ban_duration`, and `id`.

  Nothing is confirmed unless you say so: without `email_confirm: true` the user
  exists but cannot sign in on a project that requires confirmation, and no
  confirmation mail goes out to fix that. Use `invite_user_by_email/3` when you
  want the user to receive something.
  """
  @spec create_user(client(), params()) :: {:ok, User.t()} | {:error, error()}
  def create_user(client, params) do
    with {:ok, %{body: body}} <-
           request(client, :post, "/admin/users", json: encode_params(params)) do
      {:ok, User.from_json(map(body))}
    end
  end

  @doc """
  Updates any user by id.

  Body keys are those of `create_user/2` plus `ban_duration` (a Go duration such
  as `"24h"`, or `"none"` to lift a ban).

  This is the only way to write `app_metadata`, which is exactly why RLS
  policies can trust it and cannot trust `user_metadata`.
  """
  @spec update_user_by_id(client(), String.t(), params()) :: {:ok, User.t()} | {:error, error()}
  def update_user_by_id(client, id, params) when is_binary(id) do
    with {:ok, %{body: body}} <-
           request(client, :put, "/admin/users/" <> encode(id), json: encode_params(params)) do
      {:ok, User.from_json(map(body))}
    end
  end

  @doc """
  Deletes a user by id.

  ## Options

    * `:should_soft_delete` - keep the row and only mark it deleted. Defaults to
      a hard delete.

  Returns the deleted user when GoTrue echoes it back, and `{:ok, nil}` when the
  response is empty.
  """
  @spec delete_user(client(), String.t(), keyword()) ::
          {:ok, User.t() | nil} | {:error, error()}
  def delete_user(client, id, opts \\ []) when is_binary(id) do
    body = %{"should_soft_delete" => Keyword.get(opts, :should_soft_delete, false)}

    with {:ok, %{body: response}} <-
           request(client, :delete, "/admin/users/" <> encode(id), json: body) do
      case map(response) do
        %{"id" => _id} = user -> {:ok, User.from_json(user)}
        _empty -> {:ok, nil}
      end
    end
  end

  @doc """
  Invites someone by email, sending them an invitation link.

  ## Options

    * `:data` - written to the new user's `user_metadata`.
    * `:redirect_to` - where the accepted invitation should land.

  The invited user is created immediately in an unconfirmed state; accepting the
  link verifies with `type: "invite"`, after which they set a password through
  `AshSupabase.Auth.update_user/3`.
  """
  @spec invite_user_by_email(client(), String.t(), params()) ::
          {:ok, User.t()} | {:error, error()}
  def invite_user_by_email(client, email, opts \\ []) when is_binary(email) do
    params = opts |> encode_params() |> Map.put("email", email)

    with {:ok, %{body: body}} <- request(client, :post, "/invite", json: params) do
      {:ok, User.from_json(map(body))}
    end
  end

  @doc """
  Generates an action link without sending any email.

  Body keys: `type` — `"signup"`, `"invite"`, `"magiclink"`, `"recovery"`,
  `"email_change_current"` or `"email_change_new"` — plus `email`, and
  `password` for `"signup"`, `new_email` for the email-change types, `data`, and
  `redirect_to`.

  This is the endpoint to use when you deliver mail yourself: it returns the
  same link Supabase would have emailed, alongside the raw OTP.

  Returns `%{user: %AshSupabase.Auth.User{}, properties: %{...}}` where
  `properties` holds `action_link`, `email_otp`, `hashed_token`,
  `verification_type` and `redirect_to`.
  """
  @spec generate_link(client(), params()) ::
          {:ok, %{user: User.t(), properties: map()}} | {:error, error()}
  def generate_link(client, params) do
    with {:ok, %{body: body}} <-
           request(client, :post, "/admin/generate_link", json: encode_params(params)) do
      body = map(body)

      {:ok,
       %{
         user: User.from_json(body),
         properties:
           Map.take(body, ~w(action_link email_otp hashed_token verification_type redirect_to))
       }}
    end
  end

  defp request(client, method, path, opts \\ []) do
    with {:ok, config} <- Client.config(client) do
      Client.request(config, method, Config.auth_url(config) <> path, opts)
    end
  end

  defp total_count(headers) do
    headers
    |> Map.get("x-total-count", [])
    |> List.first()
    |> case do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {count, _rest} -> count
          :error -> nil
        end

      _other ->
        nil
    end
  end

  defp map(body) when is_map(body), do: body
  defp map(_body), do: %{}

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp encode_params(params) when is_list(params) or is_map(params) do
    Enum.reduce(params, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, to_string(key), value)
    end)
  end
end
