defmodule AshSupabase.ChicagoTest15SupabaseOutageTest do
  @moduledoc """
  PRD v26.8.29 §31 "Supabase is not the system of record" / Chicago Test
  15 -- "Supabase Outage" doctrine.

  This proving ground has, by design, no actual Supabase client SDK
  dependency at all: Ash + Postgres are authoritative, and Supabase
  (PostgREST / Realtime / Auth) is a downstream *consumer* of whatever
  Ash already committed -- it never participates in the write path. So
  the direct way to demonstrate "a Supabase outage cannot block a
  canonical write" is architectural, not simulated: prove no third-party
  Supabase transport dependency exists to begin with (there is nothing
  in this application's own write path that *could* "go down"), then run
  a normal, fully authoritative Ash operation end to end and show it
  needs nothing from Supabase to succeed. The domain layer (`Todo`, its
  actions, its policies, the event log it writes to) does not import,
  alias, or depend on any Supabase-transport code path at all -- so
  Supabase's absence cannot possibly block a canonical write, which is
  exactly §31's claim.

  Note this deliberately checks for a *third-party Supabase client SDK*
  dependency specifically (substrings `"supabase_client"` /
  `"supabase-elixir"`) -- **not** the bare substring `"supabase"`, since
  this project is itself literally named `ash_supabase` and checking for
  that substring would trivially fail against its own app name in
  `mix.exs`. The absence of a Supabase *transport* dependency is the
  actual claim under test; the project's own name is not evidence either
  way.
  """

  use AshSupabase.DataCase, async: true

  @forbidden_dep_substrings ["supabase_client", "supabase-elixir"]

  test "mix.exs declares no third-party Supabase client SDK dependency" do
    mix_exs = File.read!(Path.join(File.cwd!(), "mix.exs"))
    downcased = String.downcase(mix_exs)

    offenders = Enum.filter(@forbidden_dep_substrings, &String.contains?(downcased, &1))

    assert offenders == [],
           "mix.exs appears to declare a third-party Supabase SDK dependency: #{inspect(offenders)}"
  end

  test "a normal authoritative Ash create + read succeeds with no Supabase transport in the path" do
    user = create_user!()

    todo =
      Todo
      |> Ash.Changeset.for_create(:create, %{title: "Buy milk", user_id: user.id}, actor: user)
      |> Ash.create!()

    reloaded = Ash.get!(Todo, todo.id, actor: user)

    assert reloaded.id == todo.id
    assert reloaded.title == "Buy milk"
    assert reloaded.user_id == user.id
  end
end
