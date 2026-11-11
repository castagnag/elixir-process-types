defmodule ProcessTypes.ReconstructTest do
  use ExUnit.Case, async: true

  # Reconstruction of interfaces (Section 9 and Appendix D of the paper; GRAMMAR.md, §11).
  # The examples examples/recon_*.exs are checked by examples_test.exs; here are the
  # parts: the bounds read in normal forms, the store, the inverse image, and the mode.

  alias ProcessTypes.Printer
  alias ProcessTypes.Reconstruct.{Bounds, Solve, Store}
  alias ProcessTypes.Types

  defp int, do: Types.integer()
  defp a(name), do: Types.atom([name])

  # A variable is minted at each call of Types.var/1: a test binds each of its variables
  # once.
  defp vars(names), do: Enum.map(names, &Types.var/1)

  defp upper?(bounds, v, u),
    do: Enum.any?(bounds, fn {k, w, t} -> k == :upper and w == v and Types.equal?(t, u) end)

  defp lower?(bounds, v, l),
    do: Enum.any?(bounds, fn {k, w, t} -> k == :lower and w == v and Types.equal?(t, l) end)

  # ζ ≤ η between two variables is an upper bound of ζ and a lower bound of η.
  defp chain?(bounds, v, w), do: upper?(bounds, v, w) and lower?(bounds, w, v)

  describe "the bounds of a constraint (Definition def:recon-dec)" do
    test "clause 1: a union on the left" do
      [x, y] = vars([:x, :y])
      %{entailed: entailed} = Bounds.of(Types.union(x, y), int())
      assert upper?(entailed, x, int()) and upper?(entailed, y, int())
      assert length(entailed) == 2

      # A variable and a constructor: the normal form isolates the variable, and the
      # bound of the other operand comes from one step of saturation.
      [z, o, i] = vars([:z, :o, :i])
      %{entailed: entailed} = Bounds.of(Types.union(z, Types.pid(o)), Types.pid(i))
      assert upper?(entailed, z, Types.pid(i))
      assert chain?(entailed, i, o)
      refute Enum.any?(entailed, &match?({:lower, ^z, _}, &1))
    end

    test "clause 2: an arrow below an arrow" do
      [o, i, z, o2, i2, g] = vars([:o, :i, :z, :o2, :i2, :g])
      f = Types.arrow(int(), o, i, Types.atom())
      %{entailed: entailed} = Bounds.of(f, Types.arrow(z, o2, i2, g))

      # The domains are pointed: the bound of the argument contains the point, which
      # Store.new/2 removes.
      assert [{:upper, ^z, u}] = Enum.filter(entailed, &match?({_, ^z, _}, &1))
      assert Types.equal?(Types.unpointed(u), int())
      assert lower?(entailed, g, Types.atom())
      assert chain?(entailed, i2, i)
      assert chain?(entailed, o, o2)

      # A refinement of the arrow whose ground part contains every arrow.
      refined = Types.difference(Types.intersection(f, Types.term()), a(:x))
      %{entailed: same} = Bounds.of(refined, Types.arrow(z, o2, i2, g))
      assert chain?(same, i2, i) and chain?(same, o, o2) and lower?(same, g, Types.atom())
    end

    test "clause 3: a pid type below a pid type" do
      [t, s] = vars([:t, :s])
      assert chain?(Bounds.of(Types.pid(t), Types.pid(s)).entailed, s, t)
      assert Bounds.of(Types.pid(t), Types.pid(a(:bump))).entailed == [{:lower, t, a(:bump)}]

      refined = Types.difference(Types.intersection(Types.pid(t), Types.term()), int())
      assert chain?(Bounds.of(refined, Types.pid(s)).entailed, s, t)
    end

    test "clause 4: a tuple, split at a component when the others are inhabited" do
      # The tag selects one tuple type of the right-hand side.
      [z] = vars([:z])

      messages =
        Types.union(Types.tuple([a(:add), int()]), Types.tuple([a(:get), Types.pid(a(:r))]))

      assert Bounds.of(Types.tuple([a(:add), z]), messages).entailed == [{:upper, z, int()}]

      # Two variables: either may be empty, so no bound is entailed; dec keeps both.
      [z1, z2] = vars([:z1, :z2])

      %{entailed: entailed, all: all} =
        Bounds.of(Types.tuple([z1, z2]), Types.tuple([int(), Types.atom()]))

      assert entailed == []
      assert upper?(all, z1, int()) and upper?(all, z2, Types.atom())

      # A pid type is inhabited: the other component is bounded; the bound under the pid
      # is only in dec, since the other component may be empty.
      [o, i, z] = vars([:o, :i, :z])

      %{entailed: entailed, all: all} =
        Bounds.of(Types.tuple([Types.pid(o), z]), Types.tuple([Types.pid(i), int()]))

      assert entailed == [{:upper, z, int()}]
      assert Enum.any?(all, &match?({_, v, _} when v in [o, i], &1))
      refute Enum.any?(entailed, &match?({_, v, _} when v in [o, i], &1))
    end

    test "refinements: (ζ ∧ g₁) ∖ g₂ ≤ t is the bound ζ ≤ t ∨ ¬g₁ ∨ g₂" do
      [z] = vars([:z])
      g1 = Types.tuple([a(:k), Types.term()])
      g2 = Types.tuple([a(:k), Types.atom()])
      t = Types.tuple([a(:k), int()])

      assert [{:upper, ^z, u}] = Bounds.of(Types.intersection(z, g1), t).entailed
      assert Types.equal?(u, Types.union(t, Types.negation(g1)))

      refined = Types.difference(Types.intersection(z, g1), g2)
      assert [{:upper, ^z, u}] = Bounds.of(refined, t).entailed
      assert Types.equal?(u, Types.union_all([t, Types.negation(g1), g2]))
    end

    test "a ground constraint and an unsatisfiable one have no bounds" do
      [t] = vars([:t])
      assert Bounds.of(int(), Types.atom()) == %{entailed: [], all: []}
      assert Bounds.of(Types.pid(t), int()) == %{entailed: [], all: []}
    end
  end

  describe "the entailed bounds are entailed (Lemma lem:recon-dec)" do
    # Every solution of a constraint is an instance of one of those that tallying
    # returns, and subtyping is preserved by substitution: a bound is entailed if it
    # holds under each of them.
    defp entailed?(s, t) do
      solutions = Types.tally([{s, t}])
      assert solutions != []

      for {kind, v, bound} <- Bounds.of(s, t).entailed, sigma <- solutions do
        {l, u} = if kind == :upper, do: {v, bound}, else: {bound, v}
        assert Types.subtype?(Types.substitute(l, sigma), Types.substitute(u, sigma))
      end

      true
    end

    test "on constraints of each form" do
      [x, y, z, o, i, o2, i2, g] = vars([:x, :y, :z, :o, :i, :o2, :i2, :g])
      f = Types.arrow(int(), o, i, Types.atom())
      k = Types.tuple([a(:k), Types.term()])

      for {s, t} <- [
            {Types.union(x, y), int()},
            {Types.union(z, Types.pid(o)), Types.pid(i)},
            {f, Types.arrow(z, o2, i2, g)},
            {Types.intersection(f, Types.arrow(Types.atom(), o, i, int())),
             Types.arrow(z, o2, i2, g)},
            {Types.pid(x), Types.pid(y)},
            {Types.tuple([a(:add), z]),
             Types.union(Types.tuple([a(:add), int()]), Types.tuple([a(:get), Types.pid(x)]))},
            {Types.tuple([x, y]), Types.tuple([int(), Types.atom()])},
            {Types.tuple([Types.pid(o), z]), Types.tuple([Types.pid(i), int()])},
            {Types.tuple([Types.pid(o), z]),
             Types.union(
               Types.tuple([Types.pid(i), int()]),
               Types.tuple([Types.pid(x), Types.atom()])
             )},
            {Types.intersection(z, k), Types.tuple([a(:k), int()])},
            {Types.difference(Types.intersection(z, k), Types.tuple([a(:k), Types.atom()])),
             Types.tuple([a(:k), x])},
            {x, Types.union(y, Types.pid(z))},
            {Types.intersection(x, y), Types.pid(z)}
          ] do
        assert entailed?(s, t)
      end
    end

    # A bound of z is read again for the variables at the top of its other side. Doing so
    # with z fixed in tallying reads the constraint for every z: here it gave term() ≤ th.
    test "a variable at the top of a bound next to a constructor that holds another one" do
      [z, e, th] = vars([:z, :e, :th])
      s = z

      t =
        Types.union(
          Types.intersection(e, Types.tuple([th])),
          Types.negation(Types.tuple([Types.term()]))
        )

      # z = e = th = none() is a solution.
      none = %{z => Types.none(), e => Types.none(), th => Types.none()}
      assert Types.subtype?(Types.substitute(s, none), Types.substitute(t, none))

      entailed = Bounds.of(s, t).entailed
      refute Enum.any?(entailed, &match?({:lower, ^th, _}, &1))
      assert lower?(entailed, e, Types.intersection(z, Types.tuple([Types.term()])))
      assert entailed?(s, t)

      for {s, t} <- [
            {Types.union(z, Types.tuple([z])), Types.union(a(:a), Types.tuple([e]))},
            {Types.union(a(:a), Types.tuple([a(:b)])),
             Types.intersection(
               z,
               Types.union(Types.tuple([z]), Types.negation(Types.tuple([Types.term()])))
             )},
            {Types.intersection(z, Types.pid(e)), Types.union(th, Types.pid(Types.tuple([z])))},
            {Types.tuple([z, e]), Types.union(th, Types.tuple([e, Types.pid(z)]))}
          ] do
        assert entailed?(s, t)
      end
    end
  end

  describe "the store of a constraint set" do
    test "chains between variables, and the variables forced to term()" do
      [x, y, z, d, e, w] = vars([:x, :y, :z, :d, :e, :w])
      store = Store.new([{x, y}, {y, z}, {Types.term(), d}, {d, e}, {w, int()}])

      assert Store.above(store, x) == MapSet.new([x, y, z])
      assert Store.above(store, z) == MapSet.new([z])
      assert Store.forced_top(store) == MapSet.new([d, e])
      assert Store.uppers(store, w) == [int()]
      assert Store.lowers(store, d) == [Types.term()]
    end

    test "the links of dec, which the entailed bounds need not contain" do
      [o, i, z] = vars([:o, :i, :z])
      store = Store.new([{Types.tuple([Types.pid(o), z]), Types.tuple([Types.pid(i), int()])}])

      # i ≤ o holds only if z is not empty.
      assert Store.linked_below(store, o) == MapSet.new([o, i])
      assert Store.above(store, i) == MapSet.new([i])
    end

    test "the point of a pointed domain is removed from the bounds of an argument" do
      [o, i, z, o2, i2, g] = vars([:o, :i, :z, :o2, :i2, :g])
      f = Types.arrow(int(), o, i, Types.atom())
      constraint = %{sub: f, sup: Types.arrow(z, o2, i2, g), kind: {:app, nil, f, z, o2, i2, g}}

      assert [u] = Store.uppers(Store.new([constraint]), z)
      assert Types.subtype?(u, int()) and Types.subtype?(int(), u)
      assert [pointed] = Store.uppers(Store.new([{constraint.sub, constraint.sup}]), z)
      refute Types.subtype?(pointed, int())
    end

    test "polarities are semantic" do
      [m] = vars([:m])
      assert Store.polarities(m) == [{m, :pos}]
      assert Store.polarities(Types.pid(m)) == [{m, :neg}]
      assert Enum.sort(Store.polarities(Types.tuple([m, Types.pid(m)]))) == [{m, :neg}, {m, :pos}]
      # m does not matter in m ∨ term().
      assert Store.polarities(Types.union(m, Types.term())) == []
    end

    test "the closure follows upper bounds positively and lower bounds negatively" do
      [x, y, z, w] = vars([:x, :y, :z, :w])
      # x ≤ pid(y), :a ≤ y, z ≤ y, w ≤ int
      store = Store.new([{x, Types.pid(y)}, {a(:a), y}, {z, y}, {w, int()}])

      closure = Store.closure(store, [{x, :pos}], MapSet.new())
      assert closure[x] == [:pos]
      assert closure[y] == [:neg]
      # z is a lower bound of the contravariant y: contravariant too (y is wanted least).
      assert closure[z] == [:neg]
      refute is_map_key(closure, w)

      assert Store.closure(store, [{x, :pos}], MapSet.new([y])) == %{x => [:pos]}
    end
  end

  describe "the inverse image of a mailbox-pure function (Definition def:recon-inverse)" do
    test "kind: (integer() -> :number) and (atom() -> :name)" do
      arrows = [%{s: int(), t: a(:number)}, %{s: Types.atom(), t: a(:name)}]
      image = &Solve.inverse_image(arrows, &1)

      assert Types.equal?(image.(a(:number)), int())
      assert Types.equal?(image.(a(:name)), Types.atom())

      assert Types.equal?(
               image.(Types.union(a(:number), a(:name))),
               Types.union(int(), Types.atom())
             )

      assert Types.empty?(image.(Types.none()))
      assert Types.empty?(image.(int()))
    end

    test "overlapping domains: the result of an application is in every codomain that applies" do
      both = Types.union(int(), Types.atom())
      arrows = [%{s: int(), t: int()}, %{s: both, t: both}]

      # On an integer both arrows apply, and the result is in integer() ∧ (integer() ∨ atom()).
      assert Types.equal?(Solve.inverse_image(arrows, int()), int())
      assert Types.equal?(Solve.inverse_image(arrows, both), both)
    end
  end

  describe "the mode" do
    defp check(source, mode), do: ProcessTypes.check_string(source, mode: mode)

    defp interfaces(result) do
      for i <- result.interfaces,
          do: {i.line, i.type && Printer.to_string(i.type, result.names)}
    end

    @adder """
    $self_interface {:sum, integer()}
    p = spawn(fn ->
      receive do
        {:add, n, from} -> send(from, {:sum, n + 1})
      end
    end)
    send(p, {:add, 1, self()})
    """

    test "inference and ground modes still require $interface" do
      for mode <- [:infer, :ground] do
        assert [%{line: 2, message: message} | _] = check(@adder, mode).diagnostics
        assert message =~ "$interface"
      end
    end

    test "the interface of an unannotated spawn is reconstructed and the program checked with it" do
      result = check(@adder, :reconstruct)
      assert result.diagnostics == []
      assert interfaces(result) == [{2, "{:add, integer(), pid({:sum, integer()})}"}]

      # With the reconstructed interface declared, inference accepts the program.
      declared =
        String.replace(
          @adder,
          "p = spawn",
          "$interface {:add, integer(), pid({:sum, integer()})}\np = spawn"
        )

      assert check(declared, :infer).diagnostics == []
    end

    test "a message outside the reconstructed interface is rejected at its send" do
      source = @adder <> "send(p, {:add, :one, self()})\nsend(p, :stop)\n"
      result = check(source, :reconstruct)
      assert Enum.map(result.diagnostics, & &1.line) == [8, 9]

      assert hd(result.diagnostics).message =~
               "the target accepts {:add, integer(), pid({:sum, integer()})}"

      assert interfaces(result) == [{2, "{:add, integer(), pid({:sum, integer()})}"}]
    end

    test "the main process without $self_interface is reconstructed" do
      source = """
      send(self(), {:n, 1})
      receive do
        {:n, k} -> k + 1
      end
      """

      result = check(source, :reconstruct)
      assert result.diagnostics == []
      assert interfaces(result) == [{nil, "{:n, integer()}"}]

      # In inference mode the interface of the main process is term(), and the branch
      # cannot add 1 to a term().
      assert Enum.map(check(source, :infer).diagnostics, & &1.line) == [3]
    end

    test "with nothing to reconstruct, the result is that of inference" do
      for example <- ~w(server_decorated server_errors counter rpc_errors) do
        source = File.read!("examples/#{example}.exs")
        inferred = check(source, :infer)
        reconstructed = check(source, :reconstruct)
        assert reconstructed.interfaces == []
        assert length(reconstructed.constraints) == length(inferred.constraints)

        assert ProcessTypes.report(reconstructed, example) ==
                 ProcessTypes.report(inferred, example)
      end
    end

    # A variable bound at the root of a receive pattern has a type variable of its own in
    # this mode; whether a branch of a case on it is dead is still decided on the refined
    # type of the receive branch, as rule i-case does.
    test "a case on a received value skips the branches that its refined type excludes" do
      dead = """
      defmodule M do
        $ (-> :ok)
        def f() do
          receive do
            x when is_atom(x) ->
              case x do
                y when is_integer(y) -> :bad
                _ -> :ok
              end
          end
        end
      end
      """

      # The main process has no $self_interface: the mode records.
      assert check(dead <> "M.f()\n", :infer).diagnostics == []
      result = check(dead <> "M.f()\n", :reconstruct)
      assert result.diagnostics == []
      assert interfaces(result) == [{nil, "atom()"}]

      # A dead branch contributes no receive to the process.
      source = """
      defmodule G do
        $ (-> integer())
        def g() do
          receive do
            {:extra, n} -> n + 1
          end
        end
      end

      $self_interface none()
      p = spawn(fn ->
        receive do
          x when is_atom(x) ->
            case x do
              y when is_integer(y) -> G.g()
              _ -> 0
            end
        end
      end)
      send(p, :a)
      """

      result = check(source, :reconstruct)
      assert result.diagnostics == []
      assert interfaces(result) == [{11, "atom()"}]
    end

    # θ_M maps the decorations of a mailbox-pure function to [none(), term()], which is
    # sound only for decorations that are variables (Lemma lem:recon-pure).
    test "a function with a written bracket is not mailbox-pure, nor are its callers" do
      source = """
      defmodule P do
        $ (integer() -> integer())@[none(), :x]
        def g(n), do: n + 1
        $ (integer() -> integer())
        def f(n), do: g(n)
      end
      $self_interface none()
      p = spawn(fn -> receive do :x -> P.f(1); :y -> 0 end end)
      send(p, :x)
      """

      result = check(source, :reconstruct)
      assert result.diagnostics == []
      assert interfaces(result) == [{8, ":x"}]
    end

    test "the failures of the solving step name their cause" do
      result = check(File.read!("examples/recon_limits_solving.exs"), :reconstruct)
      assert [polarity, cycle, _] = Enum.map(result.diagnostics, & &1.message)
      assert polarity =~ "cannot be reconstructed" and polarity =~ "both polarities"
      assert polarity =~ "declare it with $interface"
      assert cycle =~ "whose interface depends on it"
      assert Enum.all?(result.interfaces, &(&1.type == nil))
    end

    test "the experimental split is ignored" do
      split = ProcessTypes.check_string(@adder, mode: :reconstruct, split: true)

      assert ProcessTypes.report(split, "p") ==
               ProcessTypes.report(check(@adder, :reconstruct), "p")

      assert interfaces(split) == interfaces(check(@adder, :reconstruct))
    end
  end
end
