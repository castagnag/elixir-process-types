# Reconstruction (Section 9 of the paper): the bank account of recon_bank.exs with
# clients that do not conform to the reconstructed interface
#   {:balance, pid({:balance, integer()})} or {:deposit, integer()}
#   or {:withdraw, integer(), pid(:insufficient or {:ok, integer()})}.
# A client never changes the interface, which only depends on what the account reads:
# it conforms to it or it is rejected, at its own send (the checking step).
# Expected: rejected on the lines marked "error:".
# mode: reconstruct

defmodule Bank do
  $ (integer() -> none())
  def account(balance) do
    receive do
      {:deposit, n} ->
        account(balance + n)

      {:withdraw, n, from} ->
        if n <= balance do
          send(from, {:ok, balance - n})
          account(balance - n)
        else
          send(from, :insufficient)
          account(balance)
        end

      {:balance, from} ->
        send(from, {:balance, balance})
        account(balance)
    end
  end
end

$self_interface {:ok, integer()} or :insufficient or {:balance, integer()}

acct = spawn(fn -> Bank.account(100) end)

send(acct, {:deposit, 50})
send(acct, {:deposit, :fifty})            # error: the demand of the first branch
send(acct, {:withdrawal, 30, self()})     # error: no branch selects it (coverage)
send(acct, {:balance, 42})                # error: 42 is no pid

# This client cannot receive the answer :insufficient.
$interface {:ok, integer()}
spawn(fn ->
  send(acct, {:withdraw, 500, self()})    # error: the reply-to pid must accept both answers
  receive do
    {:ok, n} -> n
  end
end)
