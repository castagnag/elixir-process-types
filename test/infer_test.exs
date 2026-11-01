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

  test "the literal form of i-app, with fresh decorations, gives the same verdicts" do
    for path <- Path.wildcard(Path.expand("../examples/*.exs", __DIR__)),
        source = File.read!(path),
        not (source =~ ~r/^# slow:/m) do
      split = source =~ ~r/^# split: experimental$/m
      assert lines(source, app: :literal, split: split) == lines(source, split: split), path
    end

    for interfaces <- [["{:half, integer()}"], ["{:half, term()}"]] do
      assert lines(halve(interfaces), app: :literal) == lines(halve(interfaces))
    end
  end

  test "eliminating variables and searching for one solution give the same verdicts" do
    # The examples, except server, on which tallying all the solutions
    # of all the variables takes too long (30 to 50 s already when loop was decorated),
    # and my_server, on which these two checks add 16 s (same verdicts, 2026-11-01).
    for path <- Path.wildcard(Path.expand("../examples/*.exs", __DIR__)),
        Path.basename(path) not in ["server.exs", "my_server.exs"],
        source = File.read!(path) do
      split = source =~ ~r/^# split: experimental$/m
      opts = [split: split]
      assert lines(source, [eliminate: false, tally: :all] ++ opts) == lines(source, opts), path
      assert lines(source, [eliminate: false] ++ opts) == lines(source, opts), path
    end
  end

  test "an fn without annotation gets its own type and bracket under each arrow" do
    # GRAMMAR.md, §6: without the option split, the premises are the arrows of f and g.
    bracket = """
    defmodule P do
      $ (pid(pid(:r)), pid((-> term())@[:r, term()]) -> term())
      and (pid(pid(:s)), pid((-> term())@[:s, term()]) -> term())
      def f(t, w), do: send(w, fn -> send(t, self()) end)
    end
    """

    type = """
    defmodule P do
      $ (:x -> (-> :x)) and (:y -> (-> :y))
      def g(c), do: fn -> c end
    end
    """

    # The bracket of the target conflicts with the body under the only arrow.
    conflict = """
    defmodule P do
      $ (pid(pid(:r)), pid((-> term())@[:s, term()]) -> term())
      def f(t, w), do: send(w, fn -> send(t, self()) end)
    end
    """

    for mode <- [:infer, :ground] do
      assert lines(bracket, mode: mode) == []
      assert lines(type, mode: mode) == []
      assert lines(conflict, mode: mode) == [3]
    end
  end

  test "messages show the least solution of the variables they print, not their bound" do
    # The projection x, and the result of f.(), are bounded only through the failing
    # constraint: eliminated in the prefix that localization solves, they would be
    # printed as term().
    half = """
    $interface {:half, atom()}
    spawn(fn -> receive do
        {:half, x} -> x + 1
      end
    end)
    """

    app = "f = fn -> :a end\nf.() + 1\n"

    for {source, shown} <- [{half, "atom()"}, {app, ":a"}] do
      assert [d] = check(source).diagnostics
      assert d.message == "the left operand of + has type #{shown}, not integer()"
    end
  end

  # Section 8.3: one undecorated run_job shared by two runners whose :add payloads
  # differ. With one arrow its input decoration must bracket both interfaces, and the
  # job sent to the first runner cannot run at it; with two arrows each runner has its
  # own. Each check took more than 150 s before elimination and the search for one
  # solution.
  defp run_job(annotation) do
    """
    defmodule R do
      $ #{annotation}
      def run_job() do
        receive do
          {:run, job} -> job.()
        end
      end
    end

    $interface {:run, (-> term())} or {:add, integer()}
    w = spawn(fn -> R.run_job() end)
    send(w, {:run, fn ->
      receive do
        {:add, n} -> div(n, 2)
      end
    end})

    $interface {:run, (-> term())} or {:add, term()}
    spawn(fn -> R.run_job() end)
    """
  end

  @tag timeout: 30_000
  test "run_job shared by two runners: rejected with one arrow, accepted with two" do
    assert lines(run_job("(-> term())")) == [19]
    assert lines(run_job("(-> term()) and (-> term())")) == []
  end

  # Two runners of the same kind share one undecorated run_job: the solution is a
  # system of mutually recursive types. Solved one equation after the other (before
  # patch 09), the check took more than 100 s.
  @tag timeout: 30_000
  test "run_job shared by two runners of the same kind, undecorated" do
    program = """
    $interface {:run, (-> term())} or {:add, integer()}
    w = spawn(fn -> R.run_job() end)
    send(w, {:run, fn ->
      receive do
        {:add, n} -> div(n, 2)
      end
    end})
    """

    [module, _] = String.split(run_job("(-> term())"), "\n\n", parts: 2)
    assert lines(Enum.join([module, program, program], "\n")) == []
  end

  # Removes the decorations that the dispatcher examples write: those of the job type
  # and of the annotations of the definitions.
  defp undecorate(source) do
    source
    |> String.replace("(-> term())@[job_writes, worker]", "(-> term())")
    |> String.replace(~r/^(\s*\$ \(.*\))\s*@\s*(\w+|\[.*\])$/m, "\\1")
  end

  defp example(name), do: File.read!(Path.expand("../examples/#{name}.exs", __DIR__))

  # More than 150 s each before patch 09.
  @tag timeout: 30_000
  test "the dispatcher without any decoration" do
    source = undecorate(example("server_decorated"))
    refute source =~ ~r/^\s*\$.*@/m
    assert lines(source) == []
  end

  @tag :slow
  @tag timeout: 60_000
  test "the dispatcher with errors without any decoration" do
    source = undecorate(example("server_errors"))
    refute source =~ ~r/^\s*\$.*@/m

    marked =
      for {line, k} <- source |> String.split("\n") |> Enum.with_index(1),
          line =~ "# error:",
          do: k

    assert lines(source) == marked
  end

  test "the constraints can be inspected without solving them" do
    result = check(halve(["{:half, integer()}"]), solve: false)
    assert result.diagnostics == []
    assert Enum.all?(result.constraints, &match?(%{sub: _, sup: _, line: _}, &1))
    assert length(result.constraints) > 0
  end

  # Cases that the copied Descr could not solve before patches 06, 07 and 11.
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
