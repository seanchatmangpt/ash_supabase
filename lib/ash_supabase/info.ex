defmodule AshSupabase.Info do
  @moduledoc """
  Introspection for resources using `AshSupabase.Resource`.
  """

  alias Spark.Dsl.Extension

  @doc "Whether `resource` uses the `AshSupabase.Resource` extension."
  def supabase_resource?(resource) do
    AshSupabase.Resource in Spark.extensions(resource)
  end

  @doc "Whether this resource's table should be added to the `supabase_realtime` publication."
  def realtime?(resource) do
    Extension.get_opt(resource, [:supabase], :realtime?, true)
  end

  @doc "Whether the `anon`/`authenticated` Postgres roles get any direct grant on this table."
  def expose_via_postgrest?(resource) do
    Extension.get_opt(resource, [:supabase], :expose_via_postgrest?, false)
  end

  @doc "Whether a direct-PostgREST grant (see `expose_via_postgrest?/1`) is SELECT-only."
  def postgrest_read_only?(resource) do
    Extension.get_opt(resource, [:supabase], :postgrest_read_only?, true)
  end

  @doc "Whether the `authenticated` role (not just `anon`) gets the direct SELECT grant."
  def rls_authenticated_select?(resource) do
    Extension.get_opt(resource, [:supabase], :rls_authenticated_select?, false)
  end

  @doc """
  The action names on `resource` that `AshSupabase.Gateway` will accept
  as `{resource, action, params}` dispatch targets, and that
  `mix ash_supabase.export_ontology` emits a typed client function for.
  Empty unless explicitly configured via `supabase do gateway_actions
  [...] end`.
  """
  def gateway_actions(resource) do
    Extension.get_opt(resource, [:supabase], :gateway_actions, [])
  end

  @doc "Whether `action` on `resource` is reachable through `AshSupabase.Gateway`."
  def gateway_action?(resource, action) do
    action in gateway_actions(resource)
  end

  @doc """
  All resources across `domains` that use `AshSupabase.Resource`.

  `domains` defaults to every domain configured for `otp_app` via
  `config :otp_app, ash_domains: [...]`.
  """
  def supabase_resources(otp_app, domains \\ nil) do
    domains = domains || Application.get_env(otp_app, :ash_domains, [])

    domains
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
    |> Enum.filter(&supabase_resource?/1)
  end

  @doc """
  All resources across `domains` that expose at least one gateway
  action -- i.e. that `AshSupabase.Gateway` and
  `mix ash_supabase.export_ontology` will actually route to/generate a
  client for. A strict subset of `supabase_resources/2`.
  """
  def gateway_resources(otp_app, domains \\ nil) do
    otp_app
    |> supabase_resources(domains)
    |> Enum.filter(&(gateway_actions(&1) != []))
  end
end
