# Reconstruction (Section 9.3 of the paper): dependencies between spawns. The logger
# (line 26) forwards what it receives to the store (line 23): the demand of its branch
# {:log, x} mentions the pid variable of the store's spawn, whose only bound from above
# is the interface of the store. The store is therefore solved first and then treated
# as declared; without this order the logger would accept any payload.
# Expected: accepted.
# mode: reconstruct
# interface (line 23): {:put, integer()} or {:size, pid({:size, integer()})}
# interface (line 26): {:log, integer()}

defmodule Store do
  $ (integer() -> none())
  def loop(sum) do
    receive do
      {:put, n}     -> loop(sum + n)
      {:size, from} -> send(from, {:size, sum}); loop(sum)
    end
  end
end

$self_interface {:size, integer()}

store = spawn(fn -> Store.loop(0) end)

# The interface of this process depends on that of the store.
logger = spawn(fn ->
  receive do
    {:log, x} -> send(store, {:put, x})
  end
end)

send(logger, {:log, 3})
send(store, {:size, self()})

receive do
  {:size, n} -> n
end
