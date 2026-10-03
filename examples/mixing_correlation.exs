# Section 6.3, first unsound law: recombining the value transformation of one
# arrow with the mailbox transformation of another. Were the law valid, f would
# be applicable to 42 at the bracket [:b, :b] with result pid(:a), and the send
# below would deposit :a in a mailbox that accepts only :b.
# Expected: rejected (no arrow of M.f applies to 42 at [:b, :b]).

defmodule M do
  $ (integer() -> pid(:a))@[:a, :a] and (boolean() -> pid(:b))@[:b, :b]
  def f(_), do: self()
end

$self_interface :b
send(M.f(42), :a)          # error: M.f is not applicable to 42 at [:b, :b]
