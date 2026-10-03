# Section 6.3, third unsound law: arrows that share argument and input
# decoration would collapse, recombining output decorations and results. Were
# the law valid, M.f(:ok) would have type pid(:a or :b or :c) in a process of
# interface :b or :c, and the send below would deposit :a in its own mailbox.
# Expected: rejected (M.f(:ok) has type pid(:b or :c), which does not accept :a).

defmodule M do
  $ (:ok -> pid(:a or :c))@[:a or :c, :a or :b or :c] and (:ok -> pid(:b or :c))@[:b or :c, :a or :b or :c]
  def f(:ok), do: self()
end

$self_interface :b or :c
send(M.f(:ok), :a)         # error: pid(:b or :c) does not accept :a
