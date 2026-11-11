# Benchmark program (bench/README.md): the server of Section 2 of the paper without the
# jobs, without any decoration, and both interfaces declared. bench/bench.sh
# derives from it the variant without the $interface lines.
# Expected: accepted.

defmodule Server do
  $type worker = :bump or {:add, integer()} or {:get_total, pid({:total, integer()})}

  $ (-> none())
  def dispatcher do
    receive do
      {:connect, client} ->
        $interface worker
        spawn(fn -> serve(client) end)
        dispatcher()
    end
  end

  $ (pid({:ready, pid(worker)}) -> none())
  defp serve(client) do
    send(client, {:ready, self()})
    send(self(), :bump)
    loop(0)
  end

  $ (integer() -> none())
  defp loop(n) do
    receive do
      :bump              -> loop(n + 1)
      {:add, k}          -> loop(n + k)
      {:get_total, from} -> send(from, {:total, n}); loop(n)
    end
  end
end

$self_interface {:ready, pid(Server.worker)} or {:total, integer()}

$interface {:connect, pid({:ready, pid(Server.worker)})}
d = spawn(fn -> Server.dispatcher() end)
send(d, {:connect, self()})

receive do
  {:ready, w} ->
    send(w, {:add, 12})
    send(w, {:get_total, self()})
    receive do
      {:total, n} -> n
    end
end
