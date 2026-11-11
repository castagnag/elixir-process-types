# Reconstruction (Section 9 of the paper): a bank account, a process whose spawn has
# no $interface. Its interface is reconstructed from the receive of account/1: what
# each branch does with the message it selects bounds the payloads (the demands), and
# the patterns bound the messages accepted (the coverage). The saver, which reads
# nothing, gets the interface none(). The interfaces are shown by "show reconstructed
# interfaces" (mix typecheck --reconstruct prints them).
# Expected: accepted.
# mode: reconstruct
# interface (line 37): {:balance, pid({:balance, integer()})} or {:deposit, integer()} or {:withdraw, integer(), pid(:insufficient or {:ok, integer()})}
# interface (line 40): none()

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

# A second client, which only writes.
spawn(fn -> send(acct, {:deposit, 10}) end)

send(acct, {:withdraw, 30, self()})
send(acct, {:balance, self()})

receive do
  {:ok, n} -> n
  :insufficient -> 0
  {:balance, n} -> n
end
