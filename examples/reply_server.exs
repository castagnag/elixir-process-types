# A server that runs jobs and sends each result to the process that asked for it. Its
# interface correlates the type of the reply with the type of the job: a job that returns
# an integer comes with a pid that accepts integers, and likewise for booleans.
#
# t-receive projects the pattern {:run, from, job}, so without the option below from has
# type pid(integer()) or pid(boolean()), to which only none() can be sent, and the send of
# ReplyServer.plain is rejected. With the option, the branch is typed once per summand of
# the interface (GRAMMAR.md, §10). This is an extension of the paper, off by default:
# mix typecheck --experimental-split examples/reply_server.exs
# split: experimental
# Expected, with the option: rejected on the line marked "error:", accepted otherwise.

defmodule ReplyServer do
  $type i_job = {:run, pid(integer()), (-> integer())}
  $type b_job = {:run, pid(boolean()), (-> boolean())}
  $type iface = i_job or b_job

  $ (-> none())@[none(), iface]
  def plain() do
    receive do
      {:run, from, job} -> send(from, job.()); plain()
    end
  end
end

# In each summand of this interface the type of the reply and that of the job disagree:
# the rule types the body under each of them, and each is ill typed.
defmodule Mismatch do
  $type iface = {:run, pid(boolean()), (-> integer())}
             or {:run, pid(integer()), (-> boolean())}

  $ (-> none())@[none(), iface]
  def plain() do
    receive do
      {:run, from, job} -> send(from, job.()); plain()    # error: the reply has the wrong type
    end
  end
end

# The client receives the replies, of both types.
$self_interface integer() or boolean()

$interface ReplyServer.iface
p = spawn(fn -> ReplyServer.plain() end)
send(p, {:run, self(), fn -> 1 + 1 end})
send(p, {:run, self(), fn -> 1 < 2 end})
