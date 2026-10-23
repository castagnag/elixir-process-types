# Introduction example: synchronous RPC
# Expected: accepted; the main process returns an integer.

defmodule RPC do
  $type response = {:response, integer()}
  $type lower_bound = response
  # Other messages are allowed, but responses with a non-integer payload are not.
  $type upper_bound = response or not({:response, not(integer())})
  $type request = {:request, pid(response)}

  $ (pid(request) -> integer())@[lower_bound, upper_bound] # can be removed (3 times slower)
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
$type job = (-> term()) @ job_msg               # 3 seconds with the annotation removed
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

# ERRORS
send(server, {:spawn, fn -> send(self(), :tock) end, self()})   # error: a job writes only job_msg, not :tock
send(server, {:request, 42})                                    # error: a request must carry a pid(response), not an integer
send(server, {:response, 42})                                   # error: the server accepts requests, not responses

RPC.remote_procedure_call(42)                                   # error: the argument must be a pid(request), not an integer
not RPC.remote_procedure_call(server)                           # error: the call returns an integer, and `not` accepts only booleans

$interface :ping
pinger = spawn(fn -> receive do :ping -> :ok end end)
RPC.remote_procedure_call(pinger)                               # error: pinger accepts :ping, not requests

$interface :ping
caller = spawn(fn -> RPC.remote_procedure_call(server) end)     # error: caller's mailbox cannot receive the :response
