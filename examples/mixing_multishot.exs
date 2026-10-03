# Section 6.3, second unsound law: (s ->^{i1} u) and (s ->^{i2} u) below
# s ->^{i1 or i2} u, valid only if a mailbox were read once. Were the law
# valid, f would be applicable at [:a or :b, :a or :b]; the two receives would
# consume :a and then :b, and the case would get {:a, :b}.
# Expected: rejected (M.f is not applicable at [:a or :b, :a or :b]).

defmodule M do
  $ (:ok -> {:a, :a} or {:b, :b})@[none(), :a] and (:ok -> {:a, :a} or {:b, :b})@[none(), :b]
  def f(:ok) do
    receive do
      y1 ->
        receive do
          y2 -> {y1, y2}
        end
    end
  end
end

$self_interface :a or :b
send(self(), :a)
send(self(), :b)

case M.f(:ok) do           # error: M.f is not applicable to :ok at [:a or :b, :a or :b]
  {:a, :a} -> :ok
  {:b, :b} -> :ok
end
