defmodule AshSupabase.Test.Ontology do
  @moduledoc """
  The single, versioned identity every receipt stamps itself with (PRD
  v26.8.29 §33 "Deterministic Replay": "Receipt must contain sufficient
  identity for replay").
  """

  @version "v26.8.29"

  def version, do: @version
end
