# Section 2: a dispatcher spawns one counter worker per client; workers also
# run jobs (closures) that clients send them. Every decoration is written. All are
# optional, since inference finds them: any set of them can be removed that does not
# contain both the decorations of job and that of loop, and the check then takes from
# a tenth of a second to about 5 s (see the comments on job and loop, and
# dispatcher_undecorated.exs). Without both, inference does not finish.
# Expected: accepted.

defmodule Server do
  # A job may send job_writes to the process that runs it, and read there the messages
  # of worker, as the paper infers: job and worker are defined by mutual recursion.
  # Written $type job = (-> term()), inference finds these decorations, but checking
  # takes about 4.5 s instead of a tenth of a second (1.3 s when the decorations of
  # dispatcher and serve are removed too).
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

  # Without its decoration, the mailbox of loop is inferred from its use sites, in a
  # tenth of a second while job is decorated. If job's decorations are removed too,
  # this mailbox is the recursive type worker with unknown decorations in its job
  # component, and inference does not finish, whatever other decorations are written
  # (not within 2 minutes; the playground stops a check after 90 s): building the
  # solution of the constraints, once they are saturated, is what does not finish
  # (_claude/INFERENCE-SCALING.md of the paper).
  $ (integer() -> none()) @ worker
  defp loop(n) do
    receive do
      :bump          -> loop(n + 1)
      {:work_add, k} -> loop(n + work(k))
      {:total, from} -> send(from, {:total, n}); loop(n)
      {:run, job}    -> job.(); loop(n)
    end
  end

  # No decorations: they are inferred; in ground mode this is the least arrow
  # (integer() -> integer())@[none(), term()].
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
