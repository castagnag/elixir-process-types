defmodule ProcessTypes.SplitTest do
  use ExUnit.Case, async: true

  # The experimental option split (GRAMMAR.md, §10): a branch is typed once per summand of
  # its refined type.

  alias ProcessTypes.Types

  defp lines(source, opts) do
    ProcessTypes.check_string(source, opts).diagnostics |> Enum.map(& &1.line) |> Enum.uniq()
  end

  defp lines_in_both_modes(source, opts \\ [split: true]) do
    for mode <- [:ground, :infer], do: lines(source, [mode: mode] ++ opts)
  end

  defp a(name), do: Types.atom([name])

  describe "tuple_summands/2" do
    test "a union of two products" do
      t = Types.union(Types.tuple([a(:x), a(:r)]), Types.tuple([a(:y), a(:s)]))
      assert [_, _] = summands = Types.tuple_summands(t, 2)
      assert Types.equal?(Types.union_all(summands), t)
    end

    test "Descr merges the products that differ in one component" do
      t =
        Types.union(
          Types.tuple([a(:x), Types.pid(a(:r))]),
          Types.tuple([a(:x), Types.pid(a(:s))])
        )

      assert [summand] = Types.tuple_summands(t, 2)
      assert Types.equal?(summand, t)
    end

    test "a difference is eliminated, and the union is the type" do
      top = Types.tuple([Types.term(), Types.term()])
      t = Types.difference(top, Types.tuple([a(:a), a(:x)]))
      assert [_, _] = summands = Types.tuple_summands(t, 2)
      assert Types.equal?(Types.union_all(summands), t)

      assert Types.empty?(
               Types.intersection(Types.union_all(summands), Types.tuple([a(:a), a(:x)]))
             )
    end

    test "variables under constructors: the union is the type, also after substitution" do
      v = Types.var(:v)
      t = Types.union(Types.tuple([a(:x), v]), Types.tuple([a(:y), Types.pid(v)]))
      assert [_, _] = summands = Types.tuple_summands(t, 2)
      assert Types.equal?(Types.union_all(summands), t)

      for image <- [Types.none(), Types.integer(), Types.term()] do
        sigma = %{v => image}

        assert Types.equal?(
                 summands |> Enum.map(&Types.substitute(&1, sigma)) |> Types.union_all(),
                 Types.substitute(t, sigma)
               )
      end
    end

    test "a variable at the top has no normal form" do
      v = Types.var(:v)
      t = Types.intersection(v, Types.tuple([Types.term(), Types.term()]))
      assert Types.tuple_summands(t, 2) == [t]

      u = Types.union(v, Types.tuple([a(:x), a(:r)]))
      assert Types.tuple_summands(u, 2) == [u]
    end

    test "a recursive type is unfolded" do
      %{m: m} =
        Types.recursive(%{
          m: fn recur ->
            Types.bare_union(
              Types.tuple([a(:a), Types.pid(Types.integer())]),
              Types.tuple([a(:b), Types.pid(recur.(:m))])
            )
          end
        })

      assert [_, _] = summands = Types.tuple_summands(m, 2)
      assert Types.equal?(Types.union_all(summands), m)
    end

    test "what is not a type of tuples of that arity, or is empty, stays as it is" do
      t = Types.tuple([a(:x), a(:y)])
      assert Types.tuple_summands(t, 3) == [t]
      assert Types.tuple_summands(Types.integer(), 2) == [Types.integer()]
      assert Types.tuple_summands(Types.none(), 2) == [Types.none()]
    end
  end

  @reply_server """
  defmodule RS do
    $type i_job = {:run, pid(integer()), (-> integer())}
    $type b_job = {:run, pid(boolean()), (-> boolean())}
    $type iface = i_job or b_job

    $ (-> none())@[none(), iface]
    def plain() do
      receive do
        {:run, from, job} -> send(from, job.()); plain()
      end
    end
  end
  """

  test "the option is off by default: the correlation is lost, on the line of the send" do
    assert lines_in_both_modes(@reply_server, []) == [[9], [9]]
    assert lines_in_both_modes(@reply_server, split: false) == [[9], [9]]
  end

  test "the reply server is accepted, in both modes" do
    assert lines_in_both_modes(@reply_server) == [[], []]
  end

  test "the two sides of an intersection pattern are correlated" do
    source = """
    defmodule P do
      $type m = {:a, pid(:r)} or {:b, pid(:s)}

      $ (:a -> :r) and (:b -> :s)
      def h(:a), do: :r
      def h(:b), do: :s

      $ (m -> m)
      def f(y) do
        case y do
          {c, w} = z -> send(w, h(c)); z
        end
      end
    end
    """

    assert lines_in_both_modes(source) == [[], []]
    assert lines_in_both_modes(source, []) == [[11], [11]]
  end

  test "a match in a block is split, and the rest of the block is its scope" do
    source = """
    defmodule P do
      $type m = {:a, pid(:r)} or {:b, pid(:s)}

      $ (:a -> :r) and (:b -> :s)
      def h(:a), do: :r
      def h(:b), do: :s

      $ (m -> :r or :s)
      def f(y) do
        {c, w} = y
        v = h(c)
        send(w, v)
      end
    end
    """

    assert lines_in_both_modes(source) == [[], []]
    assert lines_in_both_modes(source, []) == [[12], [12]]
  end

  test "a nested tuple pattern is split at each level" do
    source = """
    defmodule P do
      $type m = {{:a, pid(:r)} or {:b, pid(:s)}, :k}

      $ (:a -> :r) and (:b -> :s)
      def h(:a), do: :r
      def h(:b), do: :s

      $ (m -> term())
      def f({{c, w}, _}), do: send(w, h(c))
    end
    """

    assert lines_in_both_modes(source) == [[], []]
    assert lines_in_both_modes(source, []) == [[9], [9]]
  end

  test "a pattern with one binder is not split" do
    # The rule would type {x, x} under each summand; projection gives x the union.
    source = """
    defmodule P do
      $ ({:a, integer()} or {:b, boolean()} -> {integer(), integer()} or {boolean(), boolean()})
      def f({_, x}), do: {x, x}
    end
    """

    assert lines_in_both_modes(source) == [[3], [3]]
  end

  test "a branch has the union of the types of its body under the summands" do
    source = """
    defmodule P do
      $ ({:a, integer()} or {:b, boolean()} -> {:a, integer()} or {:b, boolean()})
      def f({c, x}), do: {c, x}
    end
    """

    assert lines_in_both_modes(source) == [[], []]
    assert lines_in_both_modes(source, []) == [[3], [3]]
  end

  test "a match of an empty type keeps its scope" do
    source = """
    defmodule P do
      $ (-> none())
      def absurd(), do: absurd()

      $ (-> integer())
      def f() do
        {a, b} = absurd()
        a + b + :nope
      end
    end
    """

    assert lines_in_both_modes(source) == [[8], [8]]
  end

  describe "what stays rejected" do
    test "two receives, whose results are paired (the counterexample Pairing)" do
      source = """
      defmodule P do
        $ pid({integer(), integer()} or {boolean(), boolean()}) -> pid(integer() or boolean())
        def pairing(p) do
          $interface integer() or boolean()
          spawn(fn ->
            receive do
              x ->
                receive do
                  y -> send(p, {x, y})
                end
            end
          end)
        end
      end
      """

      assert lines_in_both_modes(source) == [[9], [9]]
    end

    test "a summand whose body is ill typed" do
      source = fn iface ->
        """
        defmodule RS do
          $type iface = #{iface}

          $ (-> none())@[none(), iface]
          def plain() do
            receive do
              {:run, from, job} -> send(from, job.()); plain()
            end
          end
        end
        """
      end

      # Descr merges these two into {:run, pid(integer()) or pid(boolean()), (-> integer())}.
      merged = "{:run, pid(integer()), (-> integer())} or {:run, pid(boolean()), (-> integer())}"
      assert lines_in_both_modes(source.(merged)) == [[7], [7]]

      # One summand is well typed, the other is not, and they are not merged.
      apart = "{:run, pid(integer()), (-> integer())} or {:run, pid(boolean()), (-> :x)}"
      assert lines_in_both_modes(source.(apart)) == [[7], [7]]
    end

    test "a clause that returns too much under one summand, with one message" do
      source = """
      defmodule P do
        $ ({:a, integer()} or {:b, boolean()} -> integer())
        def f({_, x} = _y), do: x
      end
      """

      for mode <- [:ground, :infer] do
        diagnostics = ProcessTypes.check_string(source, mode: mode, split: true).diagnostics
        assert [%{line: 3}] = diagnostics
      end
    end
  end

  describe "an fn without annotation gets its own type and bracket under each summand" do
    test "its type follows the variables of the summand" do
      source = """
      defmodule P do
        $type m = {:x, pid((-> :x))} or {:y, pid((-> :y))}
        $ (m -> term())
        def f({c, w}), do: send(w, fn -> c end)
      end
      """

      assert lines_in_both_modes(source) == [[], []]
      assert lines_in_both_modes(source, []) == [[4], [4]]
    end

    test "its bracket follows the summand, through the type of self()" do
      source = """
      defmodule P do
        $type m = {pid(pid(:r)), pid((-> term())@[:r, term()])}
               or {pid(pid(:s)), pid((-> term())@[:s, term()])}
        $ (m -> term())
        def f({t, w}), do: send(w, fn -> send(t, self()) end)
      end
      """

      assert lines_in_both_modes(source) == [[], []]
      assert lines_in_both_modes(source, []) == [[5], [5]]
    end

    test "its bracket follows the summand, through what it reads" do
      source = """
      defmodule P do
        $type m = {:a, pid((-> integer())@[none(), integer()])}
               or {:b, pid((-> boolean())@[none(), boolean()])}
        $ (m -> term())
        def f({_c, w}), do: send(w, fn -> receive do x -> x end end)
      end
      """

      assert lines_in_both_modes(source) == [[], []]
    end

    test "a summand whose bracket conflicts with the body stays rejected" do
      # In the second summand the body needs :s in the output decoration, the target forbids it.
      source = """
      defmodule P do
        $type m = {pid(pid(:r)), pid((-> term())@[:r, term()])}
               or {pid(pid(:s)), pid((-> term())@[:r, term()])}
        $ (m -> term())
        def f({t, w}), do: send(w, fn -> send(t, self()) end)
      end
      """

      assert lines_in_both_modes(source) == [[5], [5]]
    end

    test "an fn with an annotation keeps its decorations once per occurrence" do
      # The same fn as above, whose undecorated annotation has one pair of decorations.
      source = """
      defmodule P do
        $type m = {pid(pid(:r)), pid((-> term())@[:r, term()])}
               or {pid(pid(:s)), pid((-> term())@[:s, term()])}
        $ (m -> term())
        def f({t, w}) do
          $ (-> term())
          g = fn -> send(t, self()) end
          send(w, g)
        end
      end
      """

      for mode <- [:ground, :infer], do: assert(lines(source, mode: mode, split: true) != [])
    end
  end

  test "a spawned body that reads its mailbox is split in ground mode only" do
    # In inference mode it runs at a fresh bracket, a variable at the top of r (rule i-spawn).
    source = """
    $type i_job = {:run, pid(integer()), (-> integer())}
    $type b_job = {:run, pid(boolean()), (-> boolean())}
    $interface i_job or b_job
    spawn(fn ->
      receive do
        {:run, from, job} -> send(from, job.())
      end
    end)
    """

    assert lines(source, mode: :ground, split: true) == []
    assert lines(source, mode: :infer, split: true) == [6]
  end
end
