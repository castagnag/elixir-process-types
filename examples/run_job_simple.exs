# mode: infer
# Section 8.3, "When no decoration is best":
# run_job() is typed with two identical arrow types that will receive
# different decorations, one for each spawned process. If you remove the
# second arrow type, the program will not type check because of the send
# in line 17

defmodule M do
  $ (-> term()) and (-> term())    # comment line 17 out if you remove an arrow
  def run_job() do
    receive do {:run, job} -> job.() end
  end
end

$interface {:run, (-> term())} or {:add, integer()}
w = spawn(fn -> M.run_job() end)
send(w, {:run, fn -> receive do {:add, n} -> div(n, 2) end end})

$interface {:run, (-> term())} or {:add, term()}
spawn(fn -> M.run_job() end)

# You can see the various decorations or errors inferred by the system
# by trying to uncomment one or several of the lines below and checking
# the box "show decorations" on the right pane.
send(w, {:run, fn ->
0;
#receive do {:add, k} -> k + 1 end;
#receive do {:addd, k} -> k + 1 end;
#receive do {:add, k} -> not(k) end;
#receive do {:add, k} when is_boolean(k) -> not(k) end;
#send(self(),{:add,5});
#send(self(),{:add,true});
end})
