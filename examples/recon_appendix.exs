# Reconstruction: three points of Appendix D of the paper.
# Expected: accepted.
# mode: reconstruct
# interface (line 33): term()
# interface (line 42): {:m, not {:k, not integer()}}
# interface (line 60): {:count, integer()} or {:label, atom()}

defmodule Pure do
  # A mailbox-pure function with two arrows: it reads no mailbox, and calls nothing
  # that does.
  $ (integer() -> :number) and (atom() -> :name)
  def kind(x) do
    case x do
      n when is_integer(n) -> :number
      a when is_atom(a) -> :name
    end
  end

  $ (:number -> :ok)
  def number(_kind), do: :ok

  $ (:name -> :ok)
  def name(_kind), do: :ok
end

$self_interface none()

# 1. Self-sends (Definition def:recon-selfsend). This process puts every message back
# in its own mailbox. The send bounds the type of other by the output decoration of the
# process: kept as a demand, this bound would make the interface its own bound and
# leave it undetermined. It is left out, the demand is trivial, and the checking step
# verifies the send.
requeue = spawn(fn ->
  receive do
    other -> send(self(), other)
  end
end)
send(requeue, :anything)

# 2. Refinements (Definition def:recon-refinement). The case on x places its bound on
# the part of x that is a :k tuple only.
refine = spawn(fn ->
  receive do
    {:m, x} ->
      case x do
        {:k, z} -> z + 1
        _ -> 0
      end
  end
end)
send(refine, {:m, {:k, 1}})
send(refine, {:m, :other})

# 3. An overloaded mailbox-pure callee (Definitions def:recon-pure to def:recon-cstar).
# The constraint of Pure.kind(x) does not split into bounds, since the caller selects
# the arrows it uses. As Pure.kind is mailbox-pure, the bound that the code places on
# the result (:number in the first branch) gives one on the argument, by the inverse
# image of the function: the arguments on which every arrow that may apply returns
# within the bound.
pure = spawn(fn ->
  receive do
    {:count, x} -> Pure.number(Pure.kind(x))
    {:label, x} -> Pure.name(Pure.kind(x))
  end
end)
send(pure, {:count, 3})
send(pure, {:label, :big})
