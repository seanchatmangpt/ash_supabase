defmodule AshSupabase.Transaction do
  @moduledoc """
  Wrap several Ash action calls in one Ecto transaction while preserving
  Ash's "notification only after commit" guarantee (PRD v26.8.29 §5.5:
  `Notification ⇒ CommittedConsequence`) -- the guarantee
  `Ash.Reactor`'s own `transaction do ... end` block gets for free from
  `Ash.Reactor.Notifications` middleware (see
  `AshSupabase.Ledger.Transfer`), given here to any plain Elixir process
  that needs atomicity across more than one Ash action without reaching
  for the full `Ash.Reactor` DSL -- the right choice whenever the step
  graph itself is dynamic (a variable-length federation candidate walk,
  an arbitrary posting list), which `Ash.Reactor`'s static step graph
  cannot express.

  Without this, calling `Ash.create!/2` / `Ash.update!/2` etc. inside a
  raw `Repo.transaction(fn -> ... end)` block makes Ash log a "Missed N
  notifications" warning and silently drop them: not a correctness bug
  on its own (writes still commit or roll back atomically -- that part
  Ecto already guarantees), but a real gap against the notification
  invariant this architecture is supposed to hold everywhere, not just
  inside `Ash.Reactor`. This closes it, using Ash's own internal
  `:ash_started_transaction?` / `:ash_notifications` process-dictionary
  contract (see `Ash.Actions.Helpers.notify/3`) rather than reinventing
  one.
  """

  @doc """
  Run `fun` (arity 0) inside `repo.transaction/1`. `fun` should return
  `{:ok, value}` or call `repo.rollback/1` (or raise, which Ecto
  already rolls the transaction back for) on failure -- exactly the
  contract `Ecto.Repo.transaction/1` itself expects, so existing
  `Repo.transaction(fn -> ... end)` callers can switch to this with no
  other changes.

  Every Ash notification produced by calls inside `fun` is held until
  the transaction actually commits, then dispatched via
  `Ash.Notifier.notify/1`. On rollback or a raised exception,
  notifications are discarded -- never dispatched for a consequence
  that never became authoritative.
  """
  @spec run(module, (-> {:ok, term} | {:error, term})) :: {:ok, term} | {:error, term}
  def run(repo, fun) when is_function(fun, 0) do
    already_in_transaction? = Process.get(:ash_started_transaction?, false)

    try do
      case repo.transaction(fn ->
             Process.put(:ash_started_transaction?, true)
             fun.()
           end) do
        {:ok, value} ->
          Process.get(:ash_notifications, [])
          |> Enum.reverse()
          |> Ash.Notifier.notify()

          {:ok, value}

        {:error, reason} ->
          {:error, reason}
      end
    after
      unless already_in_transaction? do
        Process.delete(:ash_started_transaction?)
      end

      Process.delete(:ash_notifications)
    end
  end
end
