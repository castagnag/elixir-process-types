# Section 2: the client sends that the worker's interface rejects: two messages,
# and two jobs that overstep, one on the write side and one on the read side.
# The Server module is the one of dispatcher.exs (see there the cost of removing decorations).
# Expected: rejected, with one error on each line marked "error:".

defmodule Server do
  $type job_writes = :bump or {:work_add, integer()}
  $type job        = (-> term())@[job_writes, worker]
  $type worker     = :bump or {:work_add, integer()} or {:total, pid({:total, integer()})}
                     or {:run, job}

  $ (-> none())@[none(), {:connect, pid({:ready, pid(worker)})}]
  def dispatcher do
    receive do
      {:connect, client} ->
        $interface worker
        spawn(fn -> serve(client) end)
        dispatcher()
    end
  end

  $ (pid({:ready, pid(worker)}) -> none()) @ worker
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

$self_interface {:ready, pid(Server.worker)} or {:total, integer()}

$interface {:connect, pid({:ready, pid(Server.worker)})}
d = spawn(fn -> Server.dispatcher() end)
send(d, {:connect, self()})

receive do
  {:ready, w} ->
    send(w, {:wrk_add, 12})                                # error: no message of worker has tag :wrk_add
    send(w, {:total, 42})                                  # error: 42 is not a pid({:total, integer()})
    send(w, {:run, fn -> send(self(), :tick) end})         # error: a job sends only job_writes to its runner
    send(w, {:run, fn -> receive do x -> x + 1 end end})   # error: the job may read :bump, and :bump + 1 fails
end
