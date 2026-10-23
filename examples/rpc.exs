# Introduction example: synchronous RPC
# Expected: accepted; the main process returns an integer.

defmodule RPC do
  $type response = {:response, integer()}
  $type lower_bound = response
  # Other messages are allowed, but responses with a non-integer payload are not.
  $type upper_bound = response or not({:response, not(integer())})
  $type request = {:request, pid(response)}

  $ (pid(request) -> integer())@[lower_bound, upper_bound] # removable decoration (3 times slower)
  def remote_procedure_call(server) do
    send(server, {:request, self()})
    receive do
      {:response, y} -> y + 1
    end
  end
end

$self_interface RPC.upper_bound

# A job may write to and read the mailbox of the process that runs it, as long as it
# keeps to job_msg: its decorations are [job_msg, job_msg], and the process spawned
# for it has the interface job_msg.
$type job_msg = :tick or {:count, integer()}
$type job = (-> term()) @ job_msg                          # removable decoration (3 seconds slower)
$type spawn_request = {:spawn, job, pid(pid(job_msg))}
$interface RPC.request or spawn_request
server = spawn(fn ->
  receive do
    {:request, reply_to} -> send(reply_to, {:response, 42})
    {:spawn, job, reply_to} ->
      $interface job_msg
      spawned = spawn(fn -> job.() end)
      send(reply_to, spawned)
  end
end)

# ok: the server returns 42, and the call returns 43
RPC.remote_procedure_call(server) + 1

# ok: the server spawns a job that returns :ok, and sends the spawned pid to the main process
send(server, {:spawn, fn -> :ok end, self()})

# ok: Writes :tick to its own mailbox, then reads it back and a count.
send(server, {:spawn, fn ->
                 send(self(), :tick)
                 receive do
                   :tick -> send(self(), {:count, 1})
                   {:count, n} -> n + 1
                 end
               end, self()})
