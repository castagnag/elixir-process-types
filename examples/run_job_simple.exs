# mode: infer
# Section 8.3, "When no decoration is best":
# run_job() is typed with two identical arrow types that will receive
# different decorations, one for each spawned process. If you remove the
# second arrow type, the program will not type check because of the send
# in line 17

defmodule M do
  $ (-> term()) and (-> term())    # if remove one arrow you must comment out line 17
  def run_job() do
    receive do {:run, job} -> job.() end
  end
end

$interface {:run, (-> term())} or {:add, integer()}
w = spawn(fn -> M.run_job() end)
send(w, {:run, fn -> receive do {:add, n} -> div(n, 2) end end})

$interface {:run, (-> term())} or {:add, term()}
spawn(fn -> M.run_job() end)
