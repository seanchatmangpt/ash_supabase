defmodule AshSupabase.RlsTest.Recorder do
  @moduledoc false

  @doc "Stands in for `repo.query!/2`, recording the statement instead of running it."
  def record(repo, statement), do: send(self(), {:sql, repo, statement})

  @doc "A `:claims` fallback for `AshSupabase.Rls.Repo`, deriving claims from the actor."
  def claims_from_reason(%{metadata: %{actor: %{id: id}}}), do: %{"sub" => id}
  def claims_from_reason(_reason), do: nil
end

defmodule AshSupabase.RlsTest.Repo do
  @moduledoc false
  use AshPostgres.Repo, otp_app: :ash_supabase, warn_on_missing_ash_functions?: false
  use AshSupabase.Rls.Repo, exec: &AshSupabase.RlsTest.Recorder.record/2

  @impl AshPostgres.Repo
  def installed_extensions, do: []

  @impl AshPostgres.Repo
  def min_pg_version, do: Version.parse!("15.0.0")
end

defmodule AshSupabase.RlsTest.CustomRepo do
  @moduledoc false
  use AshPostgres.Repo, otp_app: :ash_supabase, warn_on_missing_ash_functions?: false

  use AshSupabase.Rls.Repo,
    anon_role: "web_anon",
    claims: &AshSupabase.RlsTest.Recorder.claims_from_reason/1,
    exec: &AshSupabase.RlsTest.Recorder.record/2

  @impl AshPostgres.Repo
  def installed_extensions, do: []

  @impl AshPostgres.Repo
  def min_pg_version, do: Version.parse!("15.0.0")
end

defmodule AshSupabase.RlsTest.PreHookRepo do
  @moduledoc false
  use AshPostgres.Repo, otp_app: :ash_supabase, warn_on_missing_ash_functions?: false

  @impl AshPostgres.Repo
  def on_transaction_begin(reason) do
    AshSupabase.RlsTest.Recorder.record(__MODULE__, {:own_hook, reason.type})
  end

  use AshSupabase.Rls.Repo, exec: &AshSupabase.RlsTest.Recorder.record/2

  @impl AshPostgres.Repo
  def installed_extensions, do: []

  @impl AshPostgres.Repo
  def min_pg_version, do: Version.parse!("15.0.0")
end

defmodule AshSupabase.RlsTest.PostHookRepo do
  @moduledoc false
  use AshPostgres.Repo, otp_app: :ash_supabase, warn_on_missing_ash_functions?: false
  use AshSupabase.Rls.Repo, exec: &AshSupabase.RlsTest.Recorder.record/2

  @impl AshPostgres.Repo
  def on_transaction_begin(reason) do
    AshSupabase.RlsTest.Recorder.record(__MODULE__, {:own_hook, reason.type})
    super(reason)
  end

  @impl AshPostgres.Repo
  def installed_extensions, do: []

  @impl AshPostgres.Repo
  def min_pg_version, do: Version.parse!("15.0.0")
end

defmodule AshSupabase.RlsTest do
  use ExUnit.Case, async: true

  alias AshSupabase.Rls

  doctest AshSupabase.Rls

  @claims_setting "select set_config('request.jwt.claims', $1, true)"

  setup do
    on_exit(&Rls.clear_claims/0)
    :ok
  end

  describe "put_claims/1 and get_claims/0" do
    test "round-trips a claim map" do
      assert :ok = Rls.put_claims(%{"sub" => "u1", "role" => "authenticated"})
      assert Rls.get_claims() == %{"sub" => "u1", "role" => "authenticated"}
    end

    test "stringifies atom keys so policies see the claim names they expect" do
      assert :ok = Rls.put_claims(%{sub: "u1", app_metadata: %{"tenant" => "acme"}})
      assert Rls.get_claims() == %{"sub" => "u1", "app_metadata" => %{"tenant" => "acme"}}
    end

    test "takes the undecoded token out of an AshSupabase.Auth.Claims struct" do
      claims = AshSupabase.Auth.Claims.from_map(%{"sub" => "u1", "exp" => 1_757_753_066})

      assert :ok = Rls.put_claims(claims)
      assert Rls.get_claims() == %{"sub" => "u1", "exp" => 1_757_753_066}
    end

    test "treats nil and an empty map as no claims" do
      assert :ok = Rls.put_claims(%{"sub" => "u1"})
      assert :ok = Rls.put_claims(nil)
      assert Rls.get_claims() == nil

      assert :ok = Rls.put_claims(%{"sub" => "u1"})
      assert :ok = Rls.put_claims(%{})
      assert Rls.get_claims() == nil
    end

    test "is nil in a fresh process" do
      assert :ok = Rls.put_claims(%{"sub" => "u1"})

      task = Task.async(fn -> Process.get(:"$ash_supabase_rls_claims") end)
      assert Task.await(task) == nil
    end

    test "is visible through $callers, which is how Ash's concurrent loads see it" do
      assert :ok = Rls.put_claims(%{"sub" => "u1"})

      task = Task.async(fn -> Rls.get_claims() end)
      assert Task.await(task) == %{"sub" => "u1"}

      nested =
        Task.async(fn ->
          inner = Task.async(fn -> Rls.get_claims() end)
          Task.await(inner)
        end)

      assert Task.await(nested) == %{"sub" => "u1"}
    end

    test "does not leak into an unrelated process" do
      assert :ok = Rls.put_claims(%{"sub" => "u1"})

      parent = self()
      spawn(fn -> send(parent, {:claims, Rls.get_claims()}) end)

      assert_receive {:claims, nil}
    end
  end

  describe "clear_claims/0" do
    test "removes the claims" do
      :ok = Rls.put_claims(%{"sub" => "u1"})

      assert :ok = Rls.clear_claims()
      assert Rls.get_claims() == nil
    end

    test "is fine when there is nothing to clear" do
      assert :ok = Rls.clear_claims()
    end
  end

  describe "put_token/1" do
    test "decodes claims without verifying the signature" do
      token = sign(%{"sub" => "u1", "role" => "authenticated"}, "the-wrong-secret-entirely")

      assert {:ok, claims} = Rls.put_token(token)
      assert claims == %{"sub" => "u1", "role" => "authenticated"}
      assert Rls.get_claims() == claims
    end

    test "rejects anything that is not a JWT" do
      assert Rls.put_token("not-a-token") == {:error, :token_malformed}
      assert Rls.put_token("") == {:error, :token_malformed}
      assert Rls.get_claims() == nil
    end
  end

  describe "with_claims/2" do
    test "returns the function's value" do
      assert Rls.with_claims(%{"sub" => "u1"}, fn -> :result end) == :result
    end

    test "sets the claims for the duration of the function" do
      assert Rls.with_claims(%{"sub" => "u1"}, fn -> Rls.get_claims() end) == %{"sub" => "u1"}
      assert Rls.get_claims() == nil
    end

    test "restores the previous claims, including nesting" do
      :ok = Rls.put_claims(%{"sub" => "outer"})

      Rls.with_claims(%{"sub" => "inner"}, fn ->
        assert Rls.get_claims() == %{"sub" => "inner"}

        Rls.with_claims(%{"sub" => "innermost"}, fn ->
          assert Rls.get_claims() == %{"sub" => "innermost"}
        end)

        assert Rls.get_claims() == %{"sub" => "inner"}
      end)

      assert Rls.get_claims() == %{"sub" => "outer"}
    end

    test "restores after a raise" do
      :ok = Rls.put_claims(%{"sub" => "outer"})

      assert_raise RuntimeError, "boom", fn ->
        Rls.with_claims(%{"sub" => "inner"}, fn -> raise "boom" end)
      end

      assert Rls.get_claims() == %{"sub" => "outer"}
    end

    test "restores after a throw and after an exit" do
      :ok = Rls.put_claims(%{"sub" => "outer"})

      catch_throw(Rls.with_claims(%{"sub" => "inner"}, fn -> throw(:nope) end))
      assert Rls.get_claims() == %{"sub" => "outer"}

      catch_exit(Rls.with_claims(%{"sub" => "inner"}, fn -> exit(:nope) end))
      assert Rls.get_claims() == %{"sub" => "outer"}
    end

    test "clears the claims again when there were none before" do
      Rls.with_claims(%{"sub" => "u1"}, fn -> :ok end)

      assert Rls.get_claims() == nil
    end

    test "nil clears the claims for the duration" do
      :ok = Rls.put_claims(%{"sub" => "outer"})

      assert Rls.with_claims(nil, fn -> Rls.get_claims() end) == nil
      assert Rls.get_claims() == %{"sub" => "outer"}
    end
  end

  describe "set_config_statements/2" do
    test "sets the claims as JSON and switches to authenticated" do
      assert Rls.set_config_statements(%{"sub" => "u1"}) == [
               {@claims_setting, [~s({"sub":"u1"})]},
               {~s(set local role "authenticated"), []}
             ]
    end

    test "clears the claims and switches to anon when there is no user" do
      assert Rls.set_config_statements(nil) == [
               {@claims_setting, [""]},
               {~s(set local role "anon"), []}
             ]
    end

    test "sends the claims as a bound parameter, never interpolated" do
      injection = %{"sub" => "'); drop table users; --"}

      assert [{sql, [param]}, _role] = Rls.set_config_statements(injection)
      assert sql == @claims_setting
      assert param == "{\"sub\":\"'); drop table users; --\"}"
      refute sql =~ "drop table"
    end

    test "takes the role from the role claim, like PostgREST does" do
      assert [_claims, role] = Rls.set_config_statements(%{"role" => "service_role"})
      assert role == {~s(set local role "service_role"), []}
    end

    test "ignores an empty role claim" do
      assert [_claims, role] = Rls.set_config_statements(%{"sub" => "u1", "role" => ""})
      assert role == {~s(set local role "authenticated"), []}
    end

    test ":role overrides both the claim and the default" do
      assert [_claims, role] =
               Rls.set_config_statements(%{"role" => "service_role"}, role: "authenticated")

      assert role == {~s(set local role "authenticated"), []}

      assert [_claims, role] = Rls.set_config_statements(nil, role: :readonly)
      assert role == {~s(set local role "readonly"), []}
    end

    test ":role false leaves the connection's role alone" do
      assert Rls.set_config_statements(%{"sub" => "u1"}, role: false) == [
               {@claims_setting, [~s({"sub":"u1"})]}
             ]

      assert Rls.set_config_statements(nil, role: nil) == [{@claims_setting, [""]}]
    end

    test ":anon_role and :authenticated_role are configurable" do
      assert [_claims, {~s(set local role "web_anon"), []}] =
               Rls.set_config_statements(nil, anon_role: "web_anon")

      assert [_claims, {~s(set local role "app_user"), []}] =
               Rls.set_config_statements(%{"sub" => "u1"}, authenticated_role: "app_user")
    end

    test ":anon_role nil leaves anonymous requests at the connection's role" do
      assert Rls.set_config_statements(nil, anon_role: nil) == [{@claims_setting, [""]}]
    end

    test "falls back to the application environment" do
      Application.put_env(:ash_supabase, :rls, anon_role: "env_anon")
      on_exit(fn -> Application.delete_env(:ash_supabase, :rls) end)

      assert [_claims, {~s(set local role "env_anon"), []}] = Rls.set_config_statements(nil)

      assert [_claims, {~s(set local role "opt_anon"), []}] =
               Rls.set_config_statements(nil, anon_role: "opt_anon")
    end

    test "refuses a role name that is not a bare identifier" do
      for role <- [~s(authenticated"; drop table users; --), "has space", "1leading", ""] do
        assert_raise ArgumentError, ~r/not a usable Postgres role name/, fn ->
          Rls.set_config_statements(nil, role: role)
        end
      end
    end

    test "refuses a role name from a token's claims just the same" do
      assert_raise ArgumentError, ~r/not a usable Postgres role name/, fn ->
        Rls.set_config_statements(%{"role" => ~s(a" ; drop table users; --)})
      end
    end

    test "accepts an AshSupabase.Auth.Claims struct" do
      claims = AshSupabase.Auth.Claims.from_map(%{"sub" => "u1", "role" => "authenticated"})

      assert Rls.set_config_statements(claims) == [
               {@claims_setting, [~s({"role":"authenticated","sub":"u1"})]},
               {~s(set local role "authenticated"), []}
             ]
    end

    test ":legacy_claim_settings emits one PostgREST 7 style setting per scalar claim" do
      claims = %{
        "sub" => "u1",
        "role" => "authenticated",
        "exp" => 1_757_753_066,
        "is_anonymous" => false,
        "app_metadata" => %{"tenant" => "acme"}
      }

      assert [_claims | rest] = Rls.set_config_statements(claims, legacy_claim_settings: true)
      {legacy, [role]} = Enum.split(rest, -1)

      assert role == {~s(set local role "authenticated"), []}

      assert legacy == [
               {"select set_config('request.jwt.claim.exp', $1, true)", ["1757753066"]},
               {"select set_config('request.jwt.claim.is_anonymous', $1, true)", ["false"]},
               {"select set_config('request.jwt.claim.role', $1, true)", ["authenticated"]},
               {"select set_config('request.jwt.claim.sub', $1, true)", ["u1"]}
             ]
    end

    test ":legacy_claim_settings skips claim names that cannot be a safe setting name" do
      claims = %{"sub" => "u1", "evil', true); drop table users; --" => "x"}

      assert [_claims, legacy, _role] =
               Rls.set_config_statements(claims, legacy_claim_settings: true)

      assert legacy == {"select set_config('request.jwt.claim.sub', $1, true)", ["u1"]}
    end

    test ":legacy_claim_settings emits nothing for an anonymous request" do
      assert Rls.set_config_statements(nil, legacy_claim_settings: true) == [
               {@claims_setting, [""]},
               {~s(set local role "anon"), []}
             ]
    end
  end

  describe "AshSupabase.Rls.Repo" do
    alias AshSupabase.RlsTest.CustomRepo
    alias AshSupabase.RlsTest.PostHookRepo
    alias AshSupabase.RlsTest.PreHookRepo
    alias AshSupabase.RlsTest.Repo

    @reason %{type: :create, metadata: %{resource: SomeResource, action: :create}}

    test "runs the anon statements when the process has no claims" do
      assert Repo.on_transaction_begin(@reason) == :ok

      assert_receive {:sql, Repo, {@claims_setting, [""]}}
      assert_receive {:sql, Repo, {~s(set local role "anon"), []}}
    end

    test "runs the authenticated statements for the process's claims" do
      :ok = Rls.put_claims(%{"sub" => "u1"})

      Repo.on_transaction_begin(@reason)

      assert_receive {:sql, Repo, {@claims_setting, [~s({"sub":"u1"})]}}
      assert_receive {:sql, Repo, {~s(set local role "authenticated"), []}}
    end

    test "sees claims set in the process that started the transaction's task" do
      :ok = Rls.put_claims(%{"sub" => "u1"})

      # The recorder records in whichever process runs the statements, so the
      # assertion has to happen inside the task.
      task =
        Task.async(fn ->
          Repo.on_transaction_begin(@reason)

          receive do
            {:sql, Repo, statement} -> statement
          after
            0 -> :no_statement
          end
        end)

      assert Task.await(task) == {@claims_setting, [~s({"sub":"u1"})]}
    end

    test "options given to the `use` are applied" do
      CustomRepo.on_transaction_begin(@reason)

      assert_receive {:sql, CustomRepo, {~s(set local role "web_anon"), []}}
    end

    test ":claims derives claims from the transaction reason when the store is empty" do
      CustomRepo.on_transaction_begin(%{type: :update, metadata: %{actor: %{id: "actor-1"}}})

      assert_receive {:sql, CustomRepo, {@claims_setting, [~s({"sub":"actor-1"})]}}
      assert_receive {:sql, CustomRepo, {~s(set local role "authenticated"), []}}
    end

    test "the process store wins over :claims" do
      :ok = Rls.put_claims(%{"sub" => "from-store"})

      CustomRepo.on_transaction_begin(%{type: :update, metadata: %{actor: %{id: "actor-1"}}})

      assert_receive {:sql, CustomRepo, {@claims_setting, [~s({"sub":"from-store"})]}}
    end

    test "composes with a hook defined before the use" do
      PreHookRepo.on_transaction_begin(@reason)

      assert_receive {:sql, PreHookRepo, {@claims_setting, [""]}}
      assert_receive {:sql, PreHookRepo, {~s(set local role "anon"), []}}
      assert_receive {:sql, PreHookRepo, {:own_hook, :create}}
    end

    test "composes with a hook defined after the use that calls super/1" do
      PostHookRepo.on_transaction_begin(@reason)

      assert_receive {:sql, PostHookRepo, {:own_hook, :create}}
      assert_receive {:sql, PostHookRepo, {@claims_setting, [""]}}
      assert_receive {:sql, PostHookRepo, {~s(set local role "anon"), []}}
    end

    test "apply_claims/3 returns the statements it ran" do
      statements =
        AshSupabase.Rls.Repo.apply_claims(Repo, @reason,
          role: "service_role",
          exec: &AshSupabase.RlsTest.Recorder.record/2
        )

      assert statements == [
               {@claims_setting, [""]},
               {~s(set local role "service_role"), []}
             ]
    end
  end

  defp sign(claims, secret) do
    {:ok, token} = Joken.Signer.sign(claims, Joken.Signer.create("HS256", secret))
    token
  end
end
