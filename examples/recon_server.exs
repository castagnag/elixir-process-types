# Reconstruction (Section 9 of the paper), on the server of Section 2: neither spawn
# has a $interface, and no arrow is decorated.
# - The worker (line 19) runs the receive of loop, through serve: its interface is the
#   type that the paper calls worker. The demand of the third branch is what bounds
#   the payload of :get_total by pid({:total, integer()}).
# - The dispatcher (line 45) runs the receive of dispatcher, not that of loop.
# - serve sends :bump to its own process: a self-send, left out of the demands and
#   verified by the checking step.
# Expected: accepted.
# mode: reconstruct
# interface (line 19): Server.worker
# interface (line 45): {:connect, pid({:ready, pid(Server.worker)})}

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
    send(w, {:get_total, self()})
    receive do
      {:total, n} -> n
    end
end
