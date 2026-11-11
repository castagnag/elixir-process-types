# Limits of the reconstruction (Section 9.6 of the paper), fourth category: the
# reconstructed interface is too large. The solving step computes it from bounds only,
# and takes at its extremum each type variable that the constraints leave unbounded:
# the interface then contains messages that the process cannot handle, and the checking
# step rejects the branch that receives them (the receiver, not a sender).
# Expected: rejected on the lines marked "error:".
# mode: reconstruct

$self_interface none()

# 1. A branch that relates two capture variables. The demand cannot say that p accepts
# x: the bound of x mentions the type of p only under pid, the interface accepts any
# pid as p and any value as x, and the send is then ill typed.
relay = spawn(fn ->
  receive do
    {:to, p, x} -> send(p, x)             # error: p need not accept x
  end
end)

# 2. A closure that the process runs and also sends away. The closure writes to the
# process that runs it. Run by the process itself, this write is a self-send, which
# the demands leave out: nothing then bounds the output decoration of the closure
# from below, it is taken at none(), and the interface takes p as the pid of a process
# that accepts closures that write nothing, which this one is not.
shipper = spawn(fn ->
  receive do
    {:job, p} ->
      job = fn -> send(self(), :tick) end
      job.()
      send(p, job)                        # error: the closure writes :tick to its runner
    :tick ->
      :ok
  end
end)

# 3. A closure forwarded to a process whose declared interface contains an arrow. The
# annotation of runner does not write the decorations of that arrow: they are type
# variables, which the demand of the branch mentions and which nothing bounds on the
# side that matters. Taken at their extrema, they make the arrow demanded of job the
# largest one, (-> term())@[term(), none()], which is not what runner accepts.
$interface {:run, (-> term())}
runner = spawn(fn ->
  receive do
    {:run, job} -> job.()
  end
end)

forwarder = spawn(fn ->
  receive do
    {:fwd, job} -> send(runner, {:run, job})   # error: job need not be one that runner runs
  end
end)

# Declared, the three are accepted.
$interface {:to, pid(integer()), integer()}
relay2 = spawn(fn ->
  receive do
    {:to, p, x} -> send(p, x)
  end
end)

$interface {:job, pid((-> :tick)@[:tick, term()])} or :tick
shipper2 = spawn(fn ->
  receive do
    {:job, p} ->
      job = fn -> send(self(), :tick) end
      job.()
      send(p, job)
    :tick ->
      :ok
  end
end)

$interface {:fwd, (-> term())}
forwarder2 = spawn(fn ->
  receive do
    {:fwd, job} -> send(runner, {:run, job})
  end
end)
