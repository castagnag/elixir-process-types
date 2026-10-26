# Section 4.1: an overloaded function whose arrows act differently on the mailbox.
# Each arrow keeps its own decorations: a worker (whose interface contains
# {:add, integer()}) may call counter(3); the client may call counter(:total) but not
# counter(3). The mixed arrow (the value part of the first arrow with the mailbox part
# of the second) is not derivable.
# Expected: rejected on the lines marked "error:". In inference mode either decoration
# of counter, or both, can be removed: they are inferred (in under a tenth of a
# second).

defmodule Counter do
  $type worker = :bump or {:add, integer()} or {:get_total, pid({:total, integer()})}

  $ (integer() -> {:add, integer()})@[{:add, integer()}, term()]    # removable decoration
  and (:total -> integer())@[none(), not({:total, not(integer())})] # removable decoration
  def counter(k) when is_integer(k), do: send(self(), {:add, k})    # sends a request
  def counter(:total) do                                            # receives a reply
    receive do
      {:total, n} -> n
    end
  end

  $ (integer() -> {:add, integer()})@[none(), not({:total, not(integer())})]
  def mixed(k), do: counter(k)          # error: the mixed arrow is not derivable
end

$self_interface {:ready, pid(Counter.worker)} or {:total, integer()}

$interface Counter.worker
spawn(fn -> Counter.counter(3) end)     # ok: the worker accepts {:add, integer()}

Counter.counter(:total)                 # ok: the client's {:total, _} messages carry integers
Counter.counter(3)                      # error: the client does not accept {:add, integer()}
