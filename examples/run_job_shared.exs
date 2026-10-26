# Section 8.3, "When no decoration is best", with no decoration written anywhere. One
# run_job, which runs the jobs it receives, is shared by two programs: the first runs a
# worker whose :add payloads are integers (and sends it a job that needs them), the
# second a worker whose :add payloads are any term. Each program alone is typed with a
# different decoration of run_job's input (u1 for the first, u2 for the second, see
# run_job.exs), and none of the two serves both: there is no best decoration.
#
# - Single.run_job has one arrow, (-> term()), and inference may choose any decorations
#   for it: the first program fixes them, and the second runner is rejected.
# - Overloaded.run_job is annotated with two copies of that arrow, (-> term()) and
#   (-> term()), which have no decoration either. Inference gives each copy its own, and
#   each runner uses the copy that fits it: the same two programs are accepted. No
#   annotation of one arrow, decorated or not, types them.
# Expected: rejected on the line marked "error:", the other program accepted.
# mode: infer

defmodule Single do
  $ (-> term())
  def run_job() do
    receive do
      {:run, job} -> job.()
    end
  end
end

$interface {:run, (-> term())} or {:add, integer()}
w = spawn(fn -> Single.run_job() end)
send(w, {:run, fn ->
  receive do
    {:add, n} -> div(n, 2)
  end
end})

$interface {:run, (-> term())} or {:add, term()}
spawn(fn -> Single.run_job() end)     # error: {:add, term()} is not below what the job needs

defmodule Overloaded do
  $ (-> term()) and (-> term())
  def run_job() do
    receive do
      {:run, job} -> job.()
    end
  end
end

$interface {:run, (-> term())} or {:add, integer()}
w = spawn(fn -> Overloaded.run_job() end)
send(w, {:run, fn ->
  receive do
    {:add, n} -> div(n, 2)
  end
end})

$interface {:run, (-> term())} or {:add, term()}
spawn(fn -> Overloaded.run_job() end)
