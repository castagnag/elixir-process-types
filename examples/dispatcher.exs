# Section 2: a dispatcher spawns one counter worker per client; workers also
# run jobs (closures) that clients send them. Decorations are explicit.
# Expected: accepted.

defmodule Server do
  # A job may send :bump to whoever runs it, and reads nothing it relies on.
  $type job    = (-> term())@[:bump, term()]
  $type worker = :bump or {:work_add, integer()} or {:total, pid({:total, integer()})}
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
end
