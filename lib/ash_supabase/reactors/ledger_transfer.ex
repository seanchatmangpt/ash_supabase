defmodule AshSupabase.Ledger.Transfer do
  @moduledoc """
  The one Reactor every financial consequence in this proving ground
  flows through (PRD v26.8.29 §13, §18-20).

      admin → Supabase → Ash action → Ash policy → Reactor
        → resolve accounts → construct transfer → verify balanced
        → commit → receipt → Ash notification → Supabase → member

  A real `Ash.Reactor`, not a simulation of one: `verify_balanced` runs
  *before* the `transaction` step even starts (via `wait_for`), so an
  unbalanced construction (`debit_amount_cents != credit_amount_cents`,
  Chicago Test 4/20) never opens a database transaction at all -- zero
  writes, by construction, not by post-hoc rollback. Everything inside
  `transaction :post_transfer` -- both account postings and the
  receipt -- runs in one `Ash.DataLayer.transaction/5` call: an
  unauthorized actor failing the `Account` policy on `:post_debit`
  (Chicago Test 3) rolls the whole thing back, including the leg that
  already "succeeded".

  Simplification, stated plainly: `balance_cents` tracks debit = −amount,
  credit = +amount uniformly across every account kind (not a full
  normal-balance chart of accounts) -- sufficient to prove
  `sum(debits) == sum(credits)` as a hard invariant, which is what
  §5.3/§18-20 actually require.
  """

  use Ash.Reactor

  alias AshSupabase.Test.Finance.Account
  alias AshSupabase.Test.Receipts.Receipt

  ash do
    default_domain AshSupabase.Test.Domain
  end

  input(:debit_account_id)
  input(:credit_account_id)
  input(:debit_amount_cents)
  input(:credit_amount_cents)
  input(:memo)
  input(:actor)
  input(:request_id)

  step :transfer_id do
    run fn _arguments, _context -> {:ok, Ash.UUID.generate()} end
  end

  # §5.3 "Zero partial financial consequence": checked in memory, with no
  # data layer involvement whatsoever, before the transaction step is
  # even allowed to start.
  step :verify_balanced do
    argument :debit_amount_cents, input(:debit_amount_cents)
    argument :credit_amount_cents, input(:credit_amount_cents)

    run fn %{debit_amount_cents: debit, credit_amount_cents: credit}, _context ->
      cond do
        not (is_integer(debit) and debit > 0) ->
          {:error, {:refused, :financial_invariant, "debit amount must be a positive integer"}}

        not (is_integer(credit) and credit > 0) ->
          {:error, {:refused, :financial_invariant, "credit amount must be a positive integer"}}

        debit != credit ->
          {:error,
           {:refused, :financial_invariant, "sum(debits)=#{debit} != sum(credits)=#{credit}"}}

        true ->
          {:ok, :balanced}
      end
    end
  end

  step :actor_meta do
    argument :actor, input(:actor)

    run fn %{actor: actor}, _context ->
      case actor do
        nil -> {:ok, %{id: nil, type: nil}}
        %{id: id} -> {:ok, %{id: to_string(id), type: actor.__struct__ |> inspect()}}
      end
    end
  end

  step :financial_postings do
    argument :transfer_id, result(:transfer_id)
    argument :debit_account_id, input(:debit_account_id)
    argument :credit_account_id, input(:credit_account_id)
    argument :debit_amount_cents, input(:debit_amount_cents)
    argument :credit_amount_cents, input(:credit_amount_cents)
    wait_for :verify_balanced

    run fn args, _context ->
      {:ok,
       [
         %{
           "transfer_id" => args.transfer_id,
           "account_id" => args.debit_account_id,
           "direction" => "debit",
           "amount_cents" => args.debit_amount_cents
         },
         %{
           "transfer_id" => args.transfer_id,
           "account_id" => args.credit_account_id,
           "direction" => "credit",
           "amount_cents" => args.credit_amount_cents
         }
       ]}
    end
  end

  transaction :post_transfer, [Account, Receipt] do
    wait_for :verify_balanced
    return :receipt

    read_one :debit_account, Account, :by_id do
      inputs %{id: input(:debit_account_id)}
      actor input(:actor)
    end

    read_one :credit_account, Account, :by_id do
      inputs %{id: input(:credit_account_id)}
      actor input(:actor)
    end

    update :post_debit, Account, :post_debit do
      initial result(:debit_account)

      inputs %{
        amount_cents: input(:debit_amount_cents),
        transfer_id: result(:transfer_id),
        counterparty_account_id: input(:credit_account_id),
        memo: input(:memo)
      }

      actor input(:actor)
    end

    update :post_credit, Account, :post_credit do
      initial result(:credit_account)

      inputs %{
        amount_cents: input(:credit_amount_cents),
        transfer_id: result(:transfer_id),
        counterparty_account_id: input(:debit_account_id),
        memo: input(:memo)
      }

      actor input(:actor)
    end

    create :receipt, Receipt, :create do
      inputs %{
        subject_type: value("AshSupabase.Ledger.Transfer"),
        subject_id: result(:transfer_id),
        ontology_version: value(AshSupabase.Test.Ontology.version()),
        request_id: input(:request_id),
        process: value("AshSupabase.Ledger.Transfer"),
        admission: value(:admitted),
        outcome: value(:success),
        events_created: value(2),
        financial_postings: result(:financial_postings),
        actor_id: result(:actor_meta, [:id]),
        actor_type: result(:actor_meta, [:type]),
        metadata: value(%{})
      }

      actor input(:actor)
    end
  end
end
