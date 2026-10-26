# Section 8.3, "When no decoration is best": run_job runs the jobs it receives.
# A job must be able to run at the decorations of run_job, so run_job's requirement
# mentions its input decoration on both sides and is not first order. Program 1
# (a runner whose :add payloads are integers, and a job that needs them) is typed
# with run_job at [none(), u1]; program 2 (a runner whose :add payloads are any term)
# with run_job at [none(), u2]. No decoration of run_job serves both: R1 below
# rejects program 2, R2 rejects program 1.
# Without decorations, each program alone is accepted (program 1 in about a minute,
# program 2 in under a second); the two programs sharing one undecorated run_job
# cannot be typed, and inference does not finish.
# Expected: rejected on the lines marked "error:".
# mode: infer

defmodule R1 do
  $type u1 = {:add, integer()} or {:run, (-> term())@[none(), u1]}

  $ (-> term())@[none(), u1]
  def run_job() do
    receive do
      {:run, job} -> job.()
    end
  end
end

defmodule R2 do
  $type u2 = {:add, term()} or {:run, (-> term())@[none(), u2]}

  $ (-> term())@[none(), u2]
  def run_job() do
    receive do
      {:run, job} -> job.()
    end
  end
end

# Program 1 and program 2 with R1.
$interface {:run, (-> term())} or {:add, integer()}
w = spawn(fn -> R1.run_job() end)
send(w, {:run, fn ->
  receive do
    {:add, n} -> div(n, 2)
  end
end})

$interface {:run, (-> term())} or {:add, term()}
spawn(fn -> R1.run_job() end)     # error: {:add, term()} is not below u1

# Program 1 and program 2 with R2.
$interface {:run, (-> term())} or {:add, integer()}
w = spawn(fn -> R2.run_job() end)
send(w, {:run, fn ->              # error: the job needs integer :add payloads, u2 offers term()
  receive do
    {:add, n} -> div(n, 2)
  end
end})

$interface {:run, (-> term())} or {:add, term()}
spawn(fn -> R2.run_job() end)
