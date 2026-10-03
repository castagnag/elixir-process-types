# Section 4.1: an overloaded function, typed by an intersection of arrows.
# Under each arrow the clause whose refined type is empty is skipped.
# Expected: accepted; the two calls have types integer() and boolean().

defmodule M do
  $ (integer() -> integer()) and (boolean() -> boolean())
  def negate(x) when is_integer(x), do: -x
  def negate(x) when is_boolean(x), do: not x
end

M.negate(3)
M.negate(true)
