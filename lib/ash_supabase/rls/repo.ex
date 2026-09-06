if Code.ensure_loaded?(AshPostgres.Repo) do
  defmodule AshSupabase.Rls.Repo do
    @moduledoc """
    Applies the current process's Supabase claims to every Ash transaction.

    `AshPostgres.Repo` exposes exactly one hook that runs *inside* the
    transaction Ash opens for an action, `c:AshPostgres.Repo.on_transaction_begin/1`.
    That is the only place `SET LOCAL`-style settings can be applied correctly on
    a pooled connection, so it is where this mixin puts them:

        defmodule MyApp.Repo do
          use AshPostgres.Repo, otp_app: :my_app
          use AshSupabase.Rls.Repo
        end

    Every Ash action now runs with `request.jwt.claims` set from
    `AshSupabase.Rls.get_claims/0` and the connection switched to
    `authenticated` (or `anon` when there are no claims), which is what Supabase
    RLS policies expect. See `AshSupabase.Rls` for the SQL and the reasoning
    behind it.

    ## Read actions are not transactional by default

    This is the trap worth knowing about before you rely on it. Ash read actions
    default to `transaction? false`, so no transaction is opened, so this hook
    never runs and the read is *not* scoped by the claims. Mutations are fine —
    `c:AshPostgres.Repo.prefer_transaction?/0` defaults to `true`. To have RLS
    apply to reads as well, mark them transactional:

        read :read do
          transaction? true
        end

    Without that, a read against an RLS-protected table runs as whatever role
    your repo connects with, which for most Supabase setups is a superuser-ish
    role that bypasses policies entirely. Do not treat this module as your only
    layer of authorization; Ash policies still belong on the resource.

    ## Composing with your own hook

    The generated `on_transaction_begin/1` is `defoverridable`, and it calls
    `super/1`, so hooks chain in both directions. Define yours *after* the
    `use` and call `super/1` to keep this one:

        defmodule MyApp.Repo do
          use AshPostgres.Repo, otp_app: :my_app
          use AshSupabase.Rls.Repo

          @impl AshPostgres.Repo
          def on_transaction_begin(reason) do
            :telemetry.execute([:my_app, :repo, :transaction], %{}, reason)
            super(reason)
          end
        end

    A hook defined *before* the `use` also survives: this module marks whatever
    definition it finds as overridable and delegates to it with `super/1` after
    applying the claims.

    ## Options

    Options are baked in at compile time and forwarded to
    `AshSupabase.Rls.set_config_statements/2`, so `:role`,
    `:authenticated_role`, `:anon_role` and `:legacy_claim_settings` all work
    here:

        use AshSupabase.Rls.Repo, anon_role: "web_anon"

    Two more are specific to this module:

      * `:claims` - a 1-arity function called with the
        `t:Ash.DataLayer.transaction_reason/0` when the process store is empty.
        Use it to fall back to the actor:

            use AshSupabase.Rls.Repo,
              claims: &MyApp.Rls.claims_for/1

        Note that `t:Ash.DataLayer.transaction_reason/0` carries `:actor` for
        `:update`, `:destroy` and `:read`, but **not** for `:create` — deriving
        claims from the actor alone silently drops to `anon` on creates. The
        process store filled by `AshSupabase.Plug` does not have that hole.

      * `:exec` - a 2-arity function called with `(repo, {sql, params})` for each
        statement. Defaults to `repo.query!(sql, params)`. Useful for logging,
        or in tests.
    """

    @doc false
    defmacro __using__(opts) do
      quote do
        # A hook the repo defined above this `use` is a real definition and has
        # to be made overridable before it can be wrapped; the `AshPostgres.Repo`
        # default is already overridable and asking again would raise.
        if Module.defines?(__MODULE__, {:on_transaction_begin, 1}) do
          defoverridable on_transaction_begin: 1
        end

        @impl AshPostgres.Repo
        def on_transaction_begin(reason) do
          AshSupabase.Rls.Repo.apply_claims(__MODULE__, reason, unquote(opts))
          super(reason)
        end

        defoverridable on_transaction_begin: 1
      end
    end

    @doc """
    Applies the current claims to `repo`'s connection.

    Called by the `on_transaction_begin/1` this module generates; it must run
    inside the transaction whose statements should see the claims. Exposed so a
    repo that cannot use the mixin (one built with
    `define_ecto_repo?: false`, say) can call it directly.

    Returns the statements that were executed.
    """
    @spec apply_claims(module(), Ash.DataLayer.transaction_reason(), keyword()) ::
            [AshSupabase.Rls.statement()]
    def apply_claims(repo, reason, opts \\ []) do
      {exec, opts} = Keyword.pop(opts, :exec, &default_exec/2)
      {derive, opts} = Keyword.pop(opts, :claims)

      claims = AshSupabase.Rls.get_claims() || derive_claims(derive, reason)
      statements = AshSupabase.Rls.set_config_statements(claims, opts)

      Enum.each(statements, &exec.(repo, &1))

      statements
    end

    defp derive_claims(nil, _reason), do: nil
    defp derive_claims(fun, reason) when is_function(fun, 1), do: fun.(reason)

    defp default_exec(repo, {sql, params}), do: repo.query!(sql, params)
  end
else
  defmodule AshSupabase.Rls.Repo do
    @moduledoc """
    Applies the current process's Supabase claims to every Ash transaction.

    `ash_postgres` is an optional dependency of `ash_supabase` and is not
    installed, so this module is a stub. Add it to your dependencies to use
    Supabase Row Level Security from an `AshPostgres.Repo`:

        {:ash_postgres, "~> 2.13"}
    """

    @doc false
    defmacro __using__(_opts) do
      raise AshSupabase.Error.Configuration.exception(
              message: """
              AshSupabase.Rls.Repo requires ash_postgres, which is not installed.

              It is an optional dependency, so add it to your deps and recompile:

                  {:ash_postgres, "~> 2.13"}
              """
            )
    end
  end
end
