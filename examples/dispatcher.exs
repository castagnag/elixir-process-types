# Section 2: a dispatcher spawns one counter worker per client; workers also
# run jobs (closures) that clients send them. Decorations are explicit.
# Expected: accepted.

defmodule Server do
  # A job may send job_writes to the process that runs it, and read job_reads there.
  # The paper infers job_reads to be worker, which mentions job: a recursive type,
  # not available yet. Any supertype of worker will do, so {:run, fun()} replaces
  # {:run, job}.
  $type job_writes = :bump or {:work_add, integer()}
  $type job_reads  = :bump or {:work_add, integer()} or {:total, pid({:total, integer()})}
                     or {:run, fun()}
  $type job        = (-> term())@[job_writes, job_reads]
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

  $ (pid({:ready, pid(worker)}) -> none())@[worker, worker]
  defp serve(client) do
    send(client, {:ready, self()})
    send(self(), :bump)
    loop(0)
  end

  $ (integer() -> none())@[worker, worker]
  defp loop(n) do
    receive do
      :bump          -> loop(n + 1)
      {:work_add, k} -> loop(n + work(k))
      {:total, from} -> send(from, {:total, n}); loop(n)
      {:run, job}    -> job.(); loop(n)
    end
  end

  # No decorations: the least arrow (integer() -> integer())@[none(), term()].
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
