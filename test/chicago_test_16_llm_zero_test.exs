defmodule AshSupabase.ChicagoTest16LlmZeroTest do
  @moduledoc """
  PRD v26.8.29 §14/§32 "LLM Blackout" -- a standing, permanently-enforceable
  release gate, not a simulation: this codebase has zero LLM integration
  by design (§31/§32 -- Ash alone is authoritative; no consequential
  decision in this proving ground is ever mediated by a model call), so
  the test that matters is a guard that *fails the moment anyone adds
  one*, checked against the real dependency list and the real source
  tree:

    1. `mix.exs` declares none of a curated, case-insensitive list of
       hex package name substrings for the obvious LLM/agent-framework
       SDKs.
    2. No `.ex` file under `lib/` or `test/support/` (deliberately *not*
       `test/` itself, so this very file's own strings can never trigger
       it) contains a curated set of literal LLM-call-shaped source
       substrings.
    3. Positively: normal domain flows still work with nothing to
       disable -- the gate's job is to keep this codebase LLM-free, not
       to simulate blocking a call that does not exist, so the existing
       `Todo` dual-table create/update/destroy flow must still complete
       successfully.
  """

  use AshSupabase.DataCase, async: true

  # Hex package name substrings (case-insensitive) that would indicate an
  # LLM/agent-framework SDK dependency has been added to mix.exs. Not
  # exhaustive -- a reasonable closed list of the obviously LLM-shaped
  # names, per PRD §32.
  @forbidden_deps ~w[
    openai
    anthropic
    langchain
    instructor
    gemini
    google_generative
    ollama
    llama
    bumblebee_text_generation
    cohere
    mistral
    vertex_ai
    azure_openai
    replicate
    huggingface
    groq
    perplexity
    llm_ex
  ]

  # Literal source substrings that would indicate an actual LLM call site
  # has been wired into the codebase.
  @forbidden_source_substrings [
    "OpenAI.",
    "Anthropic.",
    "ChatCompletion",
    "llm_call",
    "chat_completion"
  ]

  describe "mix.exs carries no LLM/agent-framework dependency" do
    test "the real project mix.exs contains none of the forbidden dependency name substrings" do
      mix_exs = File.read!(Path.join(File.cwd!(), "mix.exs"))
      downcased = String.downcase(mix_exs)

      offenders = Enum.filter(@forbidden_deps, &String.contains?(downcased, &1))

      assert offenders == [],
             "mix.exs appears to declare an LLM/agent-framework dependency: #{inspect(offenders)}"
    end
  end

  describe "lib/ and test/support/ carry no LLM call sites" do
    test "no .ex file under lib/ or test/support/ contains a forbidden LLM call-shaped substring" do
      files =
        Path.wildcard(Path.join(File.cwd!(), "lib/**/*.ex")) ++
          Path.wildcard(Path.join(File.cwd!(), "test/support/**/*.ex"))

      # Sanity check the scan itself isn't vacuous (i.e. the glob really
      # did find this project's source tree).
      assert files != []

      offenders =
        for file <- files,
            source = File.read!(file),
            substring <- @forbidden_source_substrings,
            String.contains?(source, substring) do
          {file, substring}
        end

      assert offenders == [],
             "found LLM-call-shaped source in files that must remain LLM-free: #{inspect(offenders)}"
    end
  end

  describe "normal domain flows still work with nothing to disable" do
    test "Todo dual-table create/update/destroy completes successfully with no LLM in the path" do
      user = create_user!()

      todo =
        Todo
        |> Ash.Changeset.for_create(:create, %{title: "Buy milk", user_id: user.id}, actor: user)
        |> Ash.create!()

      updated =
        todo
        |> Ash.Changeset.for_update(:update, %{title: "Buy oat milk", completed: true},
          actor: user
        )
        |> Ash.update!()

      assert updated.title == "Buy oat milk"
      assert updated.completed == true

      :ok =
        updated
        |> Ash.Changeset.for_destroy(:destroy, %{}, actor: user)
        |> Ash.destroy!()

      refute Repo.get(Todo, todo.id)
    end
  end
end
