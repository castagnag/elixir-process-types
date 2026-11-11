# Limits of the reconstruction (Section 9.6 of the paper), third category: the solving
# step fails, so no interface is reconstructed and the spawn must be annotated.
# Expected: rejected on the lines marked "error:".
# mode: reconstruct

$self_interface integer()

# 1. The polarity hypothesis (PH) fails. In the reply server, the type of the result of
# job.() occurs covariantly, as the codomain of the arrow demanded of job, and
# contravariantly, in the pid type demanded of from, which must accept this result. No
# value of it weakens both occurrences: for every type u the process can serve
# {:run, pid(u), (-> u)}, but not the union of two such types, and no interface is the
# most permissive.
reply = spawn(fn ->               # error: the interface cannot be reconstructed (PH)
  receive do
    {:run, from, job} -> send(from, job.())
  end
end)
send(reply, {:run, self(), fn -> 42 end})

# 2. The dependencies form a cycle. The demand of ping mentions the pid variable of
# pong's spawn (it forwards to pong), and the demand of pong mentions the output
# decoration of ping (it forwards to the pid me of ping): each interface is needed to
# compute the other, and one of the two must be declared.
ping = spawn(fn ->                # error: the interface depends on that of pong
  me = self()
  pong = spawn(fn ->              # error: the interface depends on that of ping
    receive do
      {:pong, x} -> send(me, {:ping, x})
    end
  end)
  receive do
    {:ping, x} -> send(pong, {:pong, x})
  end
end)
send(ping, {:ping, 1})
