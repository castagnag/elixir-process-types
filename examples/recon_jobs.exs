# Reconstruction (Section 9.3 of the paper): the worker of Section 2 with its branch
# {:run, job}, spawned without $interface (line 21); the dispatcher's spawn is annotated.
# The branch applies a function that the process receives, at the bracket of loop: the
# demand on job is an arrow decorated with the decorations of loop, whose extrema are
# the two ends of the bracket of the spawn. The interface is therefore the solution of
# a recursive equation (equation (9) of the paper): the worker accepts exactly the jobs
# that a process of its own interface can run. Both jobs of the main process are such.
# Expected: accepted.
# mode: reconstruct
# interface (line 21): rec t. :bump or {:run, (-> term()) @ t} or {:total, pid({:total, integer()})} or {:work_add, integer()}

defmodule Server do
  $type job    = (-> term())
  $type worker = :bump or {:work_add, integer()} or {:total, pid({:total, integer()})}
                 or {:run, job}

  $ (-> none())
  def dispatcher do
    receive do
      {:connect, client} ->
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

  $ (integer() -> none())
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
