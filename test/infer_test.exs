defmodule ProcessTypes.InferTest do
  use ExUnit.Case, async: true

  # Inference (Section 8 of the paper; GRAMMAR.md, §9): undecorated arrows get type
  # variables, the rules of Fig. fig:inference collect constraints, and tallying solves
  # them.

  defp check(source, opts \\ []), do: ProcessTypes.check_string(source, opts)
  defp lines(source, opts \\ []), do: check(source, opts).diagnostics |> Enum.map(& &1.line)

  # Section 8.3: halve has no interface of its own; its requirement is checked against
  # every runner.
  defp halve(interfaces) do
    spawns =
      Enum.map_join(interfaces, "", fn interface ->
        "$interface #{interface}\nspawn(fn -> H.halve() end)\n"
      end)

    """
    defmodule H do
      $ (-> integer())
      def halve() do
        receive do
          {:half, x} -> x * 2
        end
      end
    end
    """ <> spawns
  end

  describe "requirements (Section 8.3)" do
    test "halve runs at every interface whose :half payload is an integer" do
      assert lines(halve(["{:half, integer()}"])) == []
      assert lines(halve(["{:half, integer()} or {:triple, integer()}"])) == []

      assert lines(halve(["{:half, integer()}", "{:half, integer()} or {:triple, integer()}"])) ==
               []
    end

    test "halve does not run where :half carries something else" do
      assert lines(halve(["{:half, term()}"])) == [10]
      assert lines(halve(["{:half, integer()}", "{:half, atom()}"])) == [12]
    end

    test "a function that reads the mailbox has no interface of its own" do
      source = """
      defmodule M do
        $ (-> integer())
        def f do
          receive do
            {:n, k} -> k
          end
        end
      end
      """

      # In ground mode the arrow is (-> integer())@[none(), term()], which reads term().
      assert lines(source, mode: :ground) == [3]
      assert lines(source) == []
      assert lines(source <> "$self_interface {:n, integer()}\nM.f()\n") == []
      assert lines(source <> "$self_interface {:n, atom()}\nM.f()\n") == [10]
    end
  end

  describe "brackets" do
    test "a process sends itself only what its interface accepts" do
      assert lines("$self_interface :a\nsend(self(), :a)\n") == []
      assert lines("$self_interface :a\nsend(self(), :b)\n") == [2]
    end

    test "an unannotated fn runs at its own bracket, fixed by its uses" do
      # Ground mode types it at [none(), term()], where this send fails.
      assert lines("f = fn -> send(self(), :x) end\n", mode: :ground) == [1]
      assert lines("f = fn -> send(self(), :x) end\n") == []

      assert lines("""
             $interface :x
             spawn(fn -> send(self(), :x) end)
             """) == []

      assert lines("""
             $interface :y
             spawn(fn -> send(self(), :x) end)
             """) == [2]
    end

    test "a written decoration is kept" do
      source = """
      defmodule M do
        $ (-> integer())@[none(), {:n, integer()}]
        def f do
          receive do
            {:n, k} -> k
          end
        end
      end
      M.f()
      """

      assert lines(source) == [9]
      assert lines("$self_interface {:n, integer()}\n" <> source) == []
    end
  end

  test "the compact form of i-app gives the same verdicts" do
    for path <- Path.wildcard(Path.expand("../examples/*.exs", __DIR__)),
        source = File.read!(path),
        not (source =~ ~r/^# slow:/m) do
      assert lines(source, app: :compact) == lines(source), path
    end

    for interfaces <- [["{:half, integer()}"], ["{:half, term()}"]] do
      assert lines(halve(interfaces), app: :compact) == lines(halve(interfaces))
    end
  end

  test "the constraints can be inspected without solving them" do
    result = check(halve(["{:half, integer()}"]), solve: false)
    assert result.diagnostics == []
    assert Enum.all?(result.constraints, &match?(%{sub: _, sup: _, line: _}, &1))
    assert length(result.constraints) > 0
  end

  # Cases that the copied Descr could not solve before patches 06 and 07; the skipped one
  # is still a limit (lib/vendor/README.md).
  describe "pending on Descr" do
    test "the jobs of Section 2, with an undecorated job" do
      source = """
      $type job = (-> term())
      $type worker = :bump or {:run, job}
      $interface worker
      w = spawn(fn ->
        receive do
          {:run, j} -> j.()
          :bump -> :ok
        end
      end)
      send(w, {:run, fn -> send(self(), :bump) end})
      send(w, {:run, fn -> send(self(), :tick) end})
      """

      assert lines(source) == [11]
    end

    @tag skip: "the intersection of a recursive tuple type does not terminate"
    test "a recursive type in an undecorated annotation" do
      assert lines("""
             $type list = nil or {integer(), list}
             defmodule L do
               $ list -> integer()
               def len(nil), do: 0
               def len({_, t}), do: 1 + len(t)
             end
             L.len({1, {2, nil}})
             """) == []
    end

    test "a type recursive through written decorations, with inferred brackets" do
      assert lines("""
             $type worker = :bump or {:run, (-> term())@[:bump, worker]}
             $interface worker
             w = spawn(fn ->
               receive do
                 {:run, j} -> j.()
                 :bump -> :ok
               end
             end)
             send(w, {:run, fn -> send(self(), :bump) end})
             :ok
             """) == []
    end
  end
end
