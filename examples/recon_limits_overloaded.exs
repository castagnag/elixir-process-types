# Limits of the reconstruction (Appendix D of the paper, "An effect-overloaded
# function"). f has two arrows, and reads the mailbox under the second one only: its
# input decoration under the first arrow is free, under the second it requires the :m
# messages to carry integers. Which arrows a process running f selects depends on its
# interface, so the constraint of the call f(x) gives no bound on x (f is not
# mailbox-pure), the reconstructed interface {:m, term()} or {:v, term()} is too large,
# and the checking step rejects it: the error is reported where the process starts to
# run loop. With the spawn declared at {:v, integer()} or {:m, term()}, or at
# {:v, integer() or atom()} or {:m, integer()}, both maximal, the program is accepted;
# at their union it is not. (Here the reconstruction finds {:v, atom() or integer()},
# since the argument must be in the domain of f whatever the selection: still too large.)
# Expected: rejected on the line marked "error:".
# mode: reconstruct

defmodule Effect do
  $ (integer() -> integer()) and (atom() -> integer())
  def f(x) do
    case x do
      n when is_integer(n) -> 0
      a when is_atom(a) -> (receive do {:m, y} -> y end) + 1
    end
  end

  $ (-> none())
  def loop do
    receive do
      {:v, x} -> f(x); loop()
      {:m, _} -> loop()
    end
  end
end

$self_interface none()

spawn(fn -> Effect.loop() end)        # error: the reconstructed interface lets x be an atom, and :m carry anything
