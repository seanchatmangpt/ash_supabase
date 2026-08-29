defmodule AshSupabase.Replay do
  @moduledoc """
  Generic (not `Todo`-specific, not resource-specific at all) support for
  PRD v26.8.29 §14/§30/§34 "Read Architecture" / Chicago Test 14 --
  "Event Replay": the claim that rebuilding a resource's live projection
  table purely by replaying its `AshEvents` event log reproduces the same
  state as the original write path produced.

  "Same state" is deliberately made a *structural* claim, not merely
  "every field I remembered to compare by hand happened to still match":
  `state_hash/2` folds every public attribute of a loaded record into one
  deterministic integer, and `compare/2` says whether two such hashes --
  captured before and after a replay -- describe the same state.

  On purpose, this module knows nothing about *how* a replay happens (that
  sequencing -- load, mutate, run `Event`'s `:replay` action, reload -- is
  a property of the test that exercises a specific resource, not of this
  helper) and nothing about *which* resource it is hashing: it only knows
  how to turn "an Ash resource module + one already-loaded struct of that
  resource" into a single comparable number.
  """

  @typedoc "The integer produced by `state_hash/2`."
  @type hash :: integer()

  @typedoc "What `compare/2` returns when the two hashes differ."
  @type drift :: %{before: hash(), after: hash()}

  @doc """
  Computes a deterministic hash of `record`'s public attributes, as
  declared on `resource`.

  Pure and DB-free: it never queries anything, it only reads the fields
  already present on the given struct. Two structurally-identical
  records -- even if they are two different struct instances loaded
  through entirely different code paths (a raw `Repo.get/2`, an
  `Ash.read!/2`, before vs. after an event replay, ...) -- always produce
  the same hash, because:

    * only `Ash.Resource.Info.public_attributes/1` fields are considered
      -- Ash-internal metadata (`__meta__`, calculation/aggregate
      results, loaded-relationship state, etc.) never enters the hash at
      all, so it cannot introduce spurious drift between two otherwise
      identical records loaded two different ways.
    * the `{attribute_name, value}` pairs are sorted before hashing, so
      the result cannot depend on attribute declaration order or on
      `Map`'s unspecified internal term ordering.
  """
  @spec state_hash(resource :: module(), record :: struct()) :: hash()
  def state_hash(resource, record) do
    resource
    |> Ash.Resource.Info.public_attributes()
    |> Enum.into(%{}, fn attr -> {attr.name, Map.get(record, attr.name)} end)
    |> Map.to_list()
    |> Enum.sort()
    |> :erlang.phash2()
  end

  @doc """
  Compares two `state_hash/2` results.

  Returns `:alive` when they match -- the state described by
  `hash_after` is, structurally, the exact same state described by
  `hash_before`. Returns `{:drift, %{before: hash_before, after:
  hash_after}}` otherwise, carrying both hashes along so a caller can at
  least report *that* something changed (this module intentionally does
  not attempt to say *what* changed -- diagnosing a drift means
  re-fetching both records and comparing them field by field, which is
  outside this module's job).
  """
  @spec compare(hash_before :: hash(), hash_after :: hash()) :: :alive | {:drift, drift()}
  def compare(hash_before, hash_after) when hash_before == hash_after, do: :alive

  def compare(hash_before, hash_after) do
    {:drift, %{before: hash_before, after: hash_after}}
  end
end
