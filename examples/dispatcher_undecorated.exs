# Section 2, the program of dispatcher.exs with only loop decorated: inference finds
# the decorations of job, dispatcher and serve, in about a second. Without the
# decoration of loop, the mailbox of loop (the recursive type worker) must be found
# from its use sites, and inference does not finish (not within 2 minutes).
# Expected: accepted, in inference mode (in ground mode, undecorated arrows are the
# least ones, and the program is rejected).
# mode: infer

defmodule Server do
  $type job    = (-> term())
  $type worker = :bump or {:work_add, integer()} or {:total, pid({:total, integer()})}
                 or {:run, job}

  $ (-> none())
  def dispatcher do
    receive do
      {:connect, client} ->
        $interface worker
        spawn(fn -> serve(client) end)
        dispatcher()
    end
  end

  $ (pid({:ready, pid(worker)}) -> none())
  defp serve(client) do
    send(client, {:ready, self()})
    send(self(), :bump)
    loop(0)
  end

  $ (integer() -> none()) @ worker
  defp loop(n) do
    receive do
      :bump          -> loop(n + 1)
      {:work_add, k} -> loop(n + work(k))
      {:total, from} -> send(from, {:total, n}); loop(n)
      {:run, job}    -> job.(); loop(n)
    end
  end

  $ integer() -> integer()
  defp work(k), do: k * k
end

# The main process is a client.
$self_interface {:ready, pid(Server.worker)} or {:total, integer()}

$interface {:connect, pid({:ready, pid(Server.worker)})}
d = spawn(fn -> Server.dispatcher() end)
send(d, {:connect, self()})

receive do
  {:ready, w} ->
    send(w, {:work_add, 12})
    send(w, {:total, self()})                        # self() is the client
    send(w, {:run, fn -> send(self(), :bump) end})   # self() is the worker
    send(w, {:run, fn ->                             # reads and writes the worker's mailbox
                     receive do
                       {:work_add, 0} -> send(self(), :bump)
                       {:work_add, n} -> send(self(), {:work_add, n + 1})
                     end
                   end})
end
