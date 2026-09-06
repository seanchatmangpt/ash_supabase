if Code.ensure_loaded?(Plug.Conn) do
  defmodule AshSupabase.Plug do
    @moduledoc """
    Authenticates a request from its Supabase access token.

    A Supabase client sends the user's access token as a bearer token. This plug
    takes that token, verifies it locally with `AshSupabase.Auth.JWT.verify/3` —
    no round trip to GoTrue — and puts the result where the rest of the request
    can find it:

        conn.assigns.supabase_claims   # the verified claims
        conn.assigns.current_user      # an actor built from them

    It also hands the claims to `AshSupabase.Rls.put_claims/1`, which is what
    makes `auth.uid()` work in Row Level Security policies for anything this
    request does through an `AshPostgres.Repo` (see `AshSupabase.Rls.Repo`).

    ## Router

        pipeline :api do
          plug :accepts, ["json"]
          plug AshSupabase.Plug, client: MyApp.Supabase
        end

        pipeline :maybe_authenticated do
          plug :accepts, ["json"]
          plug AshSupabase.Plug, client: MyApp.Supabase, on_error: :continue
        end

    Order matters in two directions. It must come *after* anything that could
    change the request headers, and *before* anything that reads
    `conn.assigns.current_user` or runs an Ash action — including
    `Ash.PlugHelpers.set_actor/2`, which should be given
    `conn.assigns.current_user` from here.

    The claims are stored in the *request process*. A Phoenix controller runs
    there, so nothing more is needed; a `Task` started from the controller is
    covered too, through `$callers`. A LiveView runs in its own process and
    never sees them — call `AshSupabase.Rls.put_claims/1` in `mount/3` from the
    session instead.

    ## Options

      * `:client` - the `AshSupabase.Client` module (or config, or keyword list)
        whose key material verifies the token. Required.
      * `:claims_assign` - assign for the verified claims. Defaults to
        `:supabase_claims`.
      * `:user_assign` - assign for the actor. Defaults to `:current_user`.
      * `:user` - a 1-arity function called with the claims to build the actor.
        Defaults to a plain map of `:id`, `:email`, `:role`, `:app_metadata` and
        `:user_metadata`. Point it at your own loader to get a real record:

            plug AshSupabase.Plug,
              client: MyApp.Supabase,
              user: &MyApp.Accounts.user_from_claims/1

      * `:put_claims` - whether to populate `AshSupabase.Rls`. Defaults to
        `true`. Set it to `false` if you do not talk to Postgres directly.
      * `:verify` - options forwarded to `AshSupabase.Auth.JWT.verify/3`. Pin
        `:issuer` and `:audience` here; it is what stops a token minted by a
        different Supabase project from being accepted by yours.
      * `:on_error` - what to do when there is no usable token. One of:
        * `:halt` (default) - send `401` with a JSON body and halt.
        * `:continue` - assign `nil` to both assigns and carry on, for endpoints
          that are public but nicer when signed in.
        * a 1-arity function taking the conn. Read the reason with
          `error_reason/1`.

    ## Failure reasons

    Everything that goes wrong ends up in the same place, reachable with
    `error_reason/1`:

      * `:missing_token` - no `authorization` header.
      * `:invalid_authorization_header` - the header is not `Bearer <token>`.
      * anything `AshSupabase.Auth.JWT.verify/3` returns, e.g. `:token_expired`,
        `:signature_error`, `{:invalid_audience, aud}`.

    The `401` body deliberately does not include the reason. Telling a caller
    *why* their token was rejected is a small oracle, and the honest answer for
    all of these is the same one: sign in again.
    """

    @behaviour Plug

    import Plug.Conn

    alias AshSupabase.Auth.JWT
    alias AshSupabase.Rls

    @error_key :ash_supabase_error

    @unauthorized Jason.encode!(%{
                    "error" => "unauthorized",
                    "message" => "A valid Supabase access token is required."
                  })

    @typedoc "Why authentication failed. See the module docs."
    @type reason :: :missing_token | :invalid_authorization_header | term()

    @impl Plug
    @spec init(keyword()) :: keyword()
    def init(opts) do
      opts
      |> validate_client!()
      |> validate_on_error!()
      |> Keyword.put_new(:claims_assign, :supabase_claims)
      |> Keyword.put_new(:user_assign, :current_user)
      |> Keyword.put_new(:put_claims, true)
      |> Keyword.put_new(:on_error, :halt)
      |> Keyword.put_new(:verify, [])
    end

    @impl Plug
    @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
    def call(conn, opts) do
      with {:ok, token} <- bearer_token(conn),
           {:ok, claims} <- JWT.verify(opts[:client], token, opts[:verify]) do
        authenticated(conn, claims, opts)
      else
        {:error, reason} -> unauthenticated(conn, reason, opts)
      end
    end

    @doc """
    The reason authentication failed, or `nil`.

    Only useful downstream of `on_error: :continue` or a custom `:on_error`
    function, which are the two cases where the request survives the failure.

        def deny(conn) do
          Logger.info("rejected token: \#{inspect(AshSupabase.Plug.error_reason(conn))}")
          Plug.Conn.send_resp(conn, 403, "") |> Plug.Conn.halt()
        end
    """
    @spec error_reason(Plug.Conn.t()) :: reason() | nil
    def error_reason(%Plug.Conn{} = conn), do: conn.private[@error_key]

    defp authenticated(conn, claims, opts) do
      if opts[:put_claims], do: :ok = Rls.put_claims(claims)

      conn
      |> assign(opts[:claims_assign], claims)
      |> assign(opts[:user_assign], build_user(claims, opts[:user]))
    end

    defp unauthenticated(conn, reason, opts) do
      conn = put_private(conn, @error_key, reason)

      case opts[:on_error] do
        :halt ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, @unauthorized)
          |> halt()

        :continue ->
          conn
          |> assign(opts[:claims_assign], nil)
          |> assign(opts[:user_assign], nil)

        fun when is_function(fun, 1) ->
          fun.(conn)

        fun when is_function(fun, 2) ->
          fun.(conn, reason)
      end
    end

    # The scheme is case-insensitive (RFC 7235), and clients do send "bearer".
    defp bearer_token(conn) do
      case get_req_header(conn, "authorization") do
        [] -> {:error, :missing_token}
        [value | _rest] -> parse_authorization(value)
      end
    end

    defp parse_authorization(value) do
      case String.split(value, " ", parts: 2) do
        [scheme, token] ->
          if String.downcase(scheme) == "bearer" and String.trim(token) != "" do
            {:ok, String.trim(token)}
          else
            {:error, :invalid_authorization_header}
          end

        _other ->
          {:error, :invalid_authorization_header}
      end
    end

    defp build_user(claims, nil), do: default_user(claims)
    defp build_user(claims, fun) when is_function(fun, 1), do: fun.(claims)

    defp default_user(claims) do
      %{
        id: claim(claims, :sub),
        email: presence(claim(claims, :email)),
        phone: presence(claim(claims, :phone)),
        role: claim(claims, :role),
        app_metadata: claim(claims, :app_metadata) || %{},
        user_metadata: claim(claims, :user_metadata) || %{}
      }
    end

    # `verify/3` returns an `AshSupabase.Auth.Claims` struct, but a `:user`-less
    # caller may have swapped in anything map-shaped, so both key styles work.
    defp claim(claims, key) when is_struct(claims), do: Map.get(claims, key)

    defp claim(claims, key) when is_map(claims),
      do: Map.get(claims, Atom.to_string(key), Map.get(claims, key))

    defp claim(_claims, _key), do: nil

    # GoTrue sends "" rather than omitting an unset email or phone.
    defp presence(""), do: nil
    defp presence(value), do: value

    defp validate_client!(opts) do
      unless Keyword.has_key?(opts, :client) do
        raise ArgumentError, """
        AshSupabase.Plug requires a `:client`, e.g.

            plug AshSupabase.Plug, client: MyApp.Supabase

        It is the client whose `:jwt_secret` or JWKS endpoint verifies the token.
        """
      end

      opts
    end

    defp validate_on_error!(opts) do
      case Keyword.fetch(opts, :on_error) do
        :error -> opts
        {:ok, mode} when mode in [:halt, :continue] -> opts
        {:ok, fun} when is_function(fun, 1) when is_function(fun, 2) -> opts
        {:ok, other} -> raise ArgumentError, on_error_message(other)
      end
    end

    defp on_error_message(other) do
      """
      invalid `:on_error` for AshSupabase.Plug: #{inspect(other)}

      Expected `:halt` (401 and stop), `:continue` (assign nil and carry on), or \
      a 1-arity function taking the conn.\
      """
    end
  end
else
  defmodule AshSupabase.Plug do
    @moduledoc """
    Authenticates a request from its Supabase access token.

    `plug` is an optional dependency of `ash_supabase` and is not installed, so
    this module is a stub. Add it to your dependencies to use the plug:

        {:plug, "~> 1.15"}
    """

    @doc false
    def init(_opts), do: raise(missing_plug_error())

    @doc false
    def call(_conn, _opts), do: raise(missing_plug_error())

    defp missing_plug_error do
      AshSupabase.Error.Configuration.exception(
        message: """
        AshSupabase.Plug requires plug, which is not installed.

        It is an optional dependency, so add it to your deps and recompile:

            {:plug, "~> 1.15"}
        """
      )
    end
  end
end
