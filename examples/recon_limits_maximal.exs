# Limits of the reconstruction (Section 9.6 of the paper), second category: the
# reconstructed interface is one among several maximal interfaces, pairwise
# incomparable, and the program is typable only with another one.
# A runner accepts :stop, {:add, n} and jobs. Its reconstructed interface is
#   rec t. :stop or {:add, integer()} or {:run, (-> term()) @ t}
# whose jobs are those that a process of interface t can run. The job below reads an
# {:add, p} message and uses p as a pid: it cannot run in a process whose :add messages
# carry integers, so its send is rejected. It can run in a process of interface
#   small = :stop or {:run, (-> term()) @ small}
# which is another maximal interface (Proposition prop:recon-canonical): with the spawn
# declared at small, as in the second half, the program is accepted.
# Expected: rejected on the line marked "error:".
# mode: reconstruct

defmodule Runner do
  $ (integer() -> :ok)
  def loop(n) do
    receive do
      :stop       -> :ok
      {:add, k}   -> loop(n + k)
      {:run, job} -> job.(); loop(n)
    end
  end
end

# The same function, for the process declared below: a function has one bracket, which
# processes of different interfaces cannot share.
defmodule Declared do
  $type small = :stop or {:run, (-> term()) @ small}

  $ (integer() -> :ok)
  def loop(n) do
    receive do
      :stop       -> :ok
      {:add, k}   -> loop(n + k)
      {:run, job} -> job.(); loop(n)
    end
  end
end

$self_interface none()

r = spawn(fn -> Runner.loop(0) end)
send(r, {:add, 1})
send(r, {:run, fn -> receive do {:add, p} -> send(p, :hello) end end})   # error: this job cannot run at the reconstructed interface

$interface Declared.small
s = spawn(fn -> Declared.loop(0) end)
send(s, {:run, fn -> receive do {:add, p} -> send(p, :hello) end end})
