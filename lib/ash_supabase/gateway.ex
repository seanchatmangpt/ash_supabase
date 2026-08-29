defmodule AshSupabase.Gateway do
  @moduledoc """
  The one HTTP surface a Supabase-only client ever reaches for a write
  that must go through Ash.

  Every `AshSupabase.Resource` locks PostgREST out of direct writes
  (`expose_via_postgrest?` defaults `false`, and `mix
  ash_supabase.gen_policies` revokes `anon`/`authenticated` privileges at
  the database level -- see `AshSupabase.SQL`). That answers "how do we
  stop a client writing around Ash"; it never answered "then how does a
  client write *at all*, using nothing but the Supabase SDK it already
  knows." This module is that answer: a generic `{resource, action,
  params}` dispatcher, meant to sit behind a single, generic Supabase
  Edge Function (`supabase.functions.invoke("ash-gateway", {body: ...})`
  -- see `priv/supabase/functions/ash-gateway/index.ts`) so the client
  never sees an Ash-specific URL, header, or response shape either.

  A client that only speaks Supabase has no way to know this module, or
  Ash, or Elixir, exist at all -- it imports the generated TypeScript
  client (`mix ash_supabase.export_ontology` +
  `mix ggen_igniter.sync --pack ash-supabase-client-pack`, see
  `priv/ggen/ash-supabase-client-pack/`) and calls a plain, typed local
  function like `createTodo(supabase, {title, user_id})`.

  ## Request contract

  `POST /` with a JSON body `{"resource": "todos", "action": "create",
  "params": {...}}` and an `Authorization: Bearer <supabase-jwt>` header.
  The JWT is verified with `AshSupabase.Auth.verify/3` (same as any other
  Ash entry point in this library) and its actor is what every Ash
  policy in the dispatched action sees -- a gateway call carries exactly
  the same authority a direct `Ash.create!/2` call from trusted Elixir
  code would, no more.

  `resource` is matched against the *table name* (`postgres do table
  "..." end`) of every resource returned by
  `AshSupabase.Info.gateway_resources/2` -- not the Elixir module name,
  which a client must never need to know. `action` must be one of that
  resource's own `supabase do gateway_actions [...] end` list; anything
  else (a real action a resource simply didn't opt in for) is refused
  identically to an action that doesn't exist at all -- a client can't
  distinguish "wrong name" from "not exposed," which is the point: an
  un-opted-in action is invisible, not merely forbidden.

  Only `:create`, `:update`, and `:destroy` actions are dispatchable
  today (`:update`/`:destroy` additionally require an `"id"` key in
  `params`, used to load the record via `Ash.get/3` -- itself subject to
  the resource's own read policies -- before the action runs; note that
  Ash's own security convention means a record the actor can't read
  comes back `404`, not `403` -- Ash never confirms a record you aren't
  allowed to see actually exists, and this gateway preserves that rather
  than papering over it). Read access is deliberately NOT this module's
  job: a client already gets
  reads for free, directly from Supabase, via ordinary PostgREST
  `SELECT`s (see `expose_via_postgrest?`) or Realtime -- Ash only ever
  needs to mediate the writes.

  ## Mounting it

      # in a Phoenix router:
      forward "/functions/v1/ash-gateway", to: AshSupabase.Gateway,
        init_opts: [otp_app: :my_app, jwt_secret: {MyApp.Secrets, :jwt_secret, []}]

      # or standalone, via Plug.Cowboy/Bandit:
      Bandit.start_link(plug: {AshSupabase.Gateway, otp_app: :my_app, jwt_secret: "..."}, port: 4001)

  `jwt_secret` may be a literal binary or an `{module, function, args}`
  tuple resolved on every request (for a secret pulled from runtime
  config/a secrets manager rather than compiled in).
  """

  use Plug.Router

  alias AshSupabase.Auth

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  @dispatchable_action_types [:create, :update, :destroy]

  @impl Plug
  def call(conn, opts) do
    conn
    |> Plug.Conn.put_private(:ash_supabase_gateway, normalize_opts(opts))
    |> super(opts)
  end

  defp normalize_opts(opts) do
    %{
      otp_app: Keyword.fetch!(opts, :otp_app),
      jwt_secret: Keyword.fetch!(opts, :jwt_secret),
      verifier: Keyword.get(opts, :verifier, Auth.HS256),
      audience: Keyword.get(opts, :audience, "authenticated")
    }
  end

  post "/" do
    handle_dispatch(conn, conn.private.ash_supabase_gateway)
  end

  match _ do
    json_resp(conn, 404, error_map("not_found", "no such gateway route"))
  end

  defp handle_dispatch(conn, gateway) do
    with {:ok, token} <- fetch_bearer_token(conn),
         {:ok, jwt_secret} <- resolve_jwt_secret(gateway.jwt_secret),
         {:ok, actor} <-
           Auth.verify(token, jwt_secret, verifier: gateway.verifier, audience: gateway.audience),
         {:ok, resource, action, action_type} <-
           resolve_target(gateway.otp_app, conn.body_params),
         {:ok, result} <-
           dispatch_action(
             resource,
             action,
             action_type,
             conn.body_params["params"] || %{},
             actor
           ) do
      json_resp(conn, 200, %{data: serialize(resource, result)})
    else
      {:error, :missing_token} ->
        json_resp(
          conn,
          401,
          error_map("unauthenticated", "missing Authorization: Bearer <token>")
        )

      {:error, reason}
      when reason in [
             :expired,
             :invalid_signature,
             :malformed_token,
             :invalid_base64,
             :invalid_json,
             :missing_alg,
             :missing_exp
           ] ->
        json_resp(conn, 401, error_map("unauthenticated", "invalid token (#{reason})"))

      {:error, {:unsupported_alg, alg}} ->
        json_resp(conn, 401, error_map("unauthenticated", "unsupported token alg: #{alg}"))

      {:error, {:invalid_audience, _} = reason} ->
        json_resp(conn, 401, error_map("unauthenticated", inspect(reason)))

      {:error, :not_found} ->
        json_resp(conn, 404, error_map("not_found", "unknown resource or action"))

      {:error, :missing_id} ->
        json_resp(conn, 422, error_map("invalid", "params.id is required for this action"))

      {:error, {:unsupported_action_type, type}} ->
        json_resp(
          conn,
          404,
          error_map("not_found", "action type #{type} is not dispatchable through the gateway")
        )

      {:error, %{} = e} ->
        {status, body} = ash_error_response(e)
        json_resp(conn, status, body)
    end
  end

  # Ash's own composite/class errors (`Ash.Error.Invalid`, `.Forbidden`,
  # ...) wrap a `:errors` list of more specific structs -- and, by
  # deliberate Ash security design, a read-policy filtering a record out
  # from under you (e.g. `Ash.get/3` for a record you can't read) comes
  # back as `Ash.Error.Invalid` wrapping `Ash.Error.Query.NotFound`, NOT
  # `Ash.Error.Forbidden` -- Ash never confirms a record you can't read
  # even exists. Checked in that priority order (not-found first) for
  # exactly that reason: a client trying to update/destroy a record it
  # can't read gets a 404, matching Ash's own "don't confirm existence"
  # choice, not a 422 from the top-level class alone or a 403 that would
  # leak "it's there, you're just not allowed."
  defp ash_error_response(error) do
    cond do
      contains_error?(error, Ash.Error.Query.NotFound) ->
        {404, error_map("not_found", safe_message(error))}

      is_struct(error, Ash.Error.Forbidden) ->
        {403, error_map("forbidden", safe_message(error))}

      is_struct(error, Ash.Error.Invalid) ->
        {422, error_map("invalid", safe_message(error))}

      true ->
        {500, error_map("internal", safe_message(error))}
    end
  end

  defp contains_error?(%{errors: errors}, type) when is_list(errors) do
    Enum.any?(errors, fn e -> is_struct(e, type) or contains_error?(e, type) end)
  end

  defp contains_error?(error, type), do: is_struct(error, type)

  defp fetch_bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> {:error, :missing_token}
    end
  end

  defp resolve_jwt_secret({module, function, args}) when is_atom(module) and is_atom(function) do
    {:ok, apply(module, function, args)}
  end

  defp resolve_jwt_secret(secret) when is_binary(secret), do: {:ok, secret}

  defp resolve_target(otp_app, %{"resource" => resource_name, "action" => action_name})
       when is_binary(resource_name) and is_binary(action_name) do
    with {:ok, resource} <- find_resource(otp_app, resource_name),
         {:ok, action} <- to_known_atom(action_name),
         true <- AshSupabase.Info.gateway_action?(resource, action) do
      {:ok, resource, action, Ash.Resource.Info.action(resource, action).type}
    else
      _ -> {:error, :not_found}
    end
  end

  defp resolve_target(_otp_app, _params), do: {:error, :not_found}

  defp find_resource(otp_app, resource_name) do
    otp_app
    |> AshSupabase.Info.gateway_resources()
    |> Enum.find(fn resource -> AshPostgres.DataLayer.Info.table(resource) == resource_name end)
    |> case do
      nil -> {:error, :not_found}
      resource -> {:ok, resource}
    end
  end

  # `String.to_existing_atom/1`, not `String.to_atom/1`: a client-supplied
  # action name must never be able to grow the atom table -- an action
  # name that was never compiled into any resource simply isn't a known
  # atom yet, and that failure is exactly "not found", not a crash.
  defp to_known_atom(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :error
  end

  defp dispatch_action(resource, action, action_type, params, actor)
       when action_type in @dispatchable_action_types do
    do_dispatch(resource, action, action_type, params, actor)
  end

  defp dispatch_action(_resource, _action, action_type, _params, _actor) do
    {:error, {:unsupported_action_type, action_type}}
  end

  defp do_dispatch(resource, action, :create, params, actor) do
    resource
    |> Ash.Changeset.for_create(action, params, actor: actor)
    |> Ash.create()
  end

  defp do_dispatch(resource, action, :update, params, actor) do
    with {:ok, id} <- fetch_id(params),
         {:ok, record} <- Ash.get(resource, id, actor: actor) do
      record
      |> Ash.Changeset.for_update(action, Map.delete(params, "id"), actor: actor)
      |> Ash.update()
    end
  end

  defp do_dispatch(resource, action, :destroy, params, actor) do
    with {:ok, id} <- fetch_id(params),
         {:ok, record} <- Ash.get(resource, id, actor: actor) do
      case record
           |> Ash.Changeset.for_destroy(action, Map.delete(params, "id"), actor: actor)
           |> Ash.destroy() do
        :ok -> {:ok, record}
        {:ok, updated} -> {:ok, updated}
        {:error, _} = error -> error
      end
    end
  end

  defp fetch_id(%{"id" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp fetch_id(_params), do: {:error, :missing_id}

  # A plain, JSON-safe map of `resource`'s public attributes -- never the
  # raw Ash struct (Jason has no encoder for it, and it carries internal
  # fields, like `__meta__`, a client has no business seeing).
  defp serialize(resource, record) do
    resource
    |> Ash.Resource.Info.public_attributes()
    |> Map.new(fn attr -> {attr.name, Map.get(record, attr.name)} end)
  end

  defp error_map(type, message), do: %{error: %{type: type, message: message}}

  # Never let an unrecognized error's raw `inspect/1` (which can include
  # struct field values -- attribute data, sometimes) leak to a client;
  # `Exception.message/1` when possible, else a fixed, safe string.
  defp safe_message(error) do
    Exception.message(error)
  rescue
    _ -> "internal error"
  end

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
