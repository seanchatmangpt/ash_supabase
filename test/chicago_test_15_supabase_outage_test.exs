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
  dependency specifically -- a `{:supabase_client, ...}` / `{:"supabase-elixir",
  ...}` tuple in `deps()` -- not the bare substring `"supabase_client"`
  anywhere in the file: this project's own generated-client tooling
  (`priv/ggen/ash-supabase-client-pack`, `priv/generated/ash_supabase_client.ts`,
  the `ash_supabase.gen_client` alias) legitimately contains that
  substring in perfectly ordinary file paths that have nothing to do
  with a dependency declaration, and a bare substring match flagged them
  as false positives. Anchoring to the actual `{:dep_name, ...}` shape
  `deps()` uses is what makes this a real check of "is a Supabase SDK a
  dependency," not "does this string appear anywhere in the file" --
  also why the bare substring `"supabase"` is never checked at all: this
  project is itself literally named `ash_supabase`, and checking for
  that substring would trivially fail against its own app name.
  """

  use AshSupabase.DataCase, async: true

  @forbidden_dep_patterns [~r/\{\s*:supabase_client\s*,/, ~r/\{\s*:"?supabase-elixir"?\s*,/]

  test "mix.exs declares no third-party Supabase client SDK dependency" do
    mix_exs = File.read!(Path.join(File.cwd!(), "mix.exs"))
    downcased = String.downcase(mix_exs)

    offenders = Enum.filter(@forbidden_dep_patterns, &Regex.match?(&1, downcased))

    assert offenders == [],
           "mix.exs appears to declare a third-party Supabase SDK dependency matching: #{inspect(offenders)}"
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
