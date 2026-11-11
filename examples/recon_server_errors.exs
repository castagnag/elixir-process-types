# Reconstruction (Section 9 of the paper), on the server of Section 2: neither spawn
# has a $interface, and no arrow is decorated.
# - The worker (line 18) runs the receive of loop, through serve: its interface is the
#   type that the paper calls worker. The demand of the third branch is what bounds
#   the payload of :get_total by pid({:total, integer()}).
# - The dispatcher (line 44) runs the receive of dispatcher, not that of loop.
# - serve sends :bump to its own process: a self-send, left out of the demands and
#   verified by the checking step.
# The two sends that Elixir accepts today (Section 2) are rejected by the checking step.
# Expected: rejected on the lines marked "error:".
# mode: reconstruct

defmodule Server do
  $ (-> none())
  def dispatcher do
    receive do
      {:connect, client} ->
        spawn(fn -> serve(client) end)
        dispatcher()
    end
  end

  $type worker = :bump or {:add, integer()} or {:get_total, pid({:total, integer()})}

  $ (pid({:ready, pid(worker)}) -> none())
  defp serve(client) do
    send(client, {:ready, self()})
    send(self(), :bump)
    loop(0)
  end

  $ (integer() -> none())
  defp loop(n) do
    receive do
      :bump              -> loop(n + 1)
      {:add, k}          -> loop(n + k)
      {:get_total, from} -> send(from, {:total, n}); loop(n)
    end
  end
end

$self_interface {:ready, pid(Server.worker)} or {:total, integer()}

d = spawn(fn -> Server.dispatcher() end)
send(d, {:connect, self()})

receive do
  {:ready, w} ->
    send(w, {:add, 12})
    send(w, {:aadd, 12})              # error: no branch selects it (coverage)
    send(w, {:get_total, 42})         # error: 42 is no pid (the demand of the third branch)
    send(w, {:get_total, self()})
    receive do
      {:total, n} -> n
    end
end
