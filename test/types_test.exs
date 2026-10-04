defmodule ProcessTypes.TypesTest do
  use ExUnit.Case, async: true

  import Kernel, except: [to_string: 1]
  import ProcessTypes.Types

  # The laws of Section 4.2 and the counterexamples of Section 6.3 of the paper,
  # checked on the encoding into Descr.

  defp a, do: atom([:a])
  defp b, do: atom([:b])
  defp c, do: atom([:c])
  defp ok, do: atom([:ok])

  describe "the summands are disjoint" do
    test "pids, arrows and tuples" do
      assert empty?(intersection(pid(a()), fun()))
      assert empty?(intersection(pid(), tuple()))
      assert empty?(intersection(fun(), tuple()))
      assert empty?(intersection(pid(), union(integer(), atom())))
    end
  end

  describe "pid laws (Proposition 4.3)" do
    test "contravariance" do
      assert subtype?(pid(union(a(), b())), pid(a()))
      refute subtype?(pid(a()), pid(union(a(), b())))
    end

    test "intersection and union" do
      assert equal?(intersection(pid(a()), pid(b())), pid(union(a(), b())))
      assert subtype?(union(pid(a()), pid(b())), pid(intersection(a(), b())))
      refute equal?(union(pid(a()), pid(b())), pid(intersection(a(), b())))
    end

    test "union law" do
      refute subtype?(pid(c()), union(pid(a()), pid(b())))
      assert subtype?(pid(union(a(), b())), union(pid(a()), pid(c())))
    end

    test "pid() is the top process type" do
      assert subtype?(pid(a()), pid())
      assert subtype?(union(pid(a()), pid(b())), pid())
      refute subtype?(pid(), union(pid(a()), pid(b())))
    end
  end

  describe "arrow factorization (Proposition 4.2)" do
    test "variance of the four components" do
      assert subtype?(
               arrow(integer(), none(), term(), boolean()),
               arrow(integer(), a(), b(), boolean())
             )

      assert subtype?(
               arrow(integer(), a(), a(), boolean()),
               arrow(integer(), union(a(), b()), a(), boolean())
             )

      refute subtype?(
               arrow(integer(), union(a(), b()), a(), boolean()),
               arrow(integer(), a(), a(), boolean())
             )

      assert subtype?(
               arrow(integer(), a(), union(a(), b()), boolean()),
               arrow(integer(), a(), a(), boolean())
             )

      refute subtype?(
               arrow(integer(), a(), a(), boolean()),
               arrow(integer(), a(), union(a(), b()), boolean())
             )
    end

    test "the point keeps the domain nonempty" do
      refute subtype?(
               arrow(none(), none(), term(), integer()),
               arrow(none(), none(), term(), boolean())
             )
    end

    test "fun() is the top function type" do
      assert subtype?(arrow(integer(), a(), b(), boolean()), fun())
      assert subtype?(arrow(none(), term(), none(), term()), fun())
    end
  end

  describe "the three unsound laws of Section 6.3 fail" do
    test "correlation across components" do
      l1 =
        intersection(arrow(integer(), a(), a(), pid(a())), arrow(boolean(), b(), b(), pid(b())))

      refute subtype?(l1, arrow(integer(), b(), b(), pid(a())))
    end

    test "multi-shot read capabilities" do
      u = union(tuple([a(), a()]), tuple([b(), b()]))
      l2 = intersection(arrow(ok(), none(), a(), u), arrow(ok(), none(), b(), u))
      refute subtype?(l2, arrow(ok(), none(), union(a(), b()), u))
    end

    test "write capability" do
      ac = union(a(), c())
      bc = union(b(), c())
      abc = union(ac, b())
      l3 = intersection(arrow(ok(), ac, abc, pid(ac)), arrow(ok(), bc, abc, pid(bc)))
      refute subtype?(l3, arrow(ok(), c(), abc, pid(abc)))
    end
  end

  describe "application (rule t-app)" do
    test "an intersection selects the arrows of the argument" do
      negate =
        intersection(
          arrow(integer(), none(), term(), integer()),
          arrow(boolean(), none(), term(), boolean())
        )

      assert {:ok, t} = apply(negate, integer(), a(), a())
      assert equal?(t, integer())
      assert {:ok, t} = apply(negate, union(integer(), boolean()), a(), a())
      assert equal?(t, union(integer(), boolean()))
      assert apply(negate, atom(), a(), a()) == :badarg
    end

    test "the bracket must narrow that of the arrow" do
      f = arrow(integer(), a(), a(), integer())
      assert {:ok, _} = apply(f, integer(), a(), a())
      assert {:ok, _} = apply(f, integer(), union(a(), b()), a())
      assert apply(f, integer(), none(), a()) == :badarg
      assert apply(f, integer(), a(), union(a(), b())) == :badarg
    end

    test "an arrow chosen by its bracket" do
      ac = union(a(), c())
      bc = union(b(), c())
      abc = union(ac, b())
      l3 = intersection(arrow(ok(), ac, abc, pid(ac)), arrow(ok(), bc, abc, pid(bc)))
      assert {:ok, t} = apply(l3, ok(), bc, bc)
      assert equal?(t, pid(bc))
    end

    test "a union of arrows" do
      f = union(arrow(integer(), none(), term(), a()), arrow(integer(), none(), term(), b()))
      assert {:ok, t} = apply(f, integer(), none(), term())
      assert equal?(t, union(a(), b()))
    end

    test "not a function" do
      assert apply(pid(a()), integer(), a(), a()) == :badfun
      assert apply(integer(), integer(), a(), a()) == :badfun
    end
  end

  describe "interfaces and arrow parts" do
    test "interface" do
      assert equal?(interface(pid(a())), a())
      assert equal?(interface(intersection(pid(a()), pid(b()))), union(a(), b()))
      assert equal?(interface(union(pid(union(a(), b())), pid(union(b(), c())))), b())
      assert equal?(interface(pid(term())), term())
      assert equal?(interface(pid()), none())
    end

    test "a single arrow" do
      job = arrow(tuple([]), a(), term(), integer())
      assert {:ok, {s, o, i, u}} = arrow_parts(job)

      assert equal?(s, tuple([])) and equal?(o, a()) and equal?(i, term()) and
               equal?(u, integer())
    end

    test "not a single arrow" do
      assert arrow_parts(
               intersection(
                 arrow(tuple([]), a(), a(), integer()),
                 arrow(tuple([]), b(), b(), integer())
               )
             ) == :error

      assert arrow_parts(
               union(arrow(tuple([]), a(), a(), integer()), arrow(integer(), b(), b(), integer()))
             ) == :error

      assert arrow_parts(pid(a())) == :error
    end
  end

  describe "recursive types" do
    # Each call builds its own recursive system, so that the comparisons below are
    # between two copies of the definitions (patch 03 of lib/vendor/).
    defp rec(definitions, name) do
      defs =
        Map.new(definitions, fn {n, source} ->
          {:ok, body} = ProcessTypes.Annotations.parse_type(source)
          {{nil, n}, {body, 1}}
        end)

      {:ok, t} = ProcessTypes.TypeSyntax.to_descr({:name, nil, name}, defs, nil)
      t
    end

    test "pid(me) = me" do
      me = rec(%{me: "pid(me)"}, :me)
      assert equal?(pid(me), me)
      assert subtype?(me, pid())
      refute subtype?(me, pid(integer()))
    end

    test "recursion through the codomain of an arrow" do
      w = rec(%{w: "(-> w)"}, :w)
      assert equal?(w, rec(%{w: "(-> w)"}, :w))
      assert subtype?(w, rec(%{v: "(-> v or :a)"}, :v))
      refute subtype?(rec(%{v: "(-> v or :a)"}, :v), w)
      refute subtype?(w, rec(%{i: "(-> integer())"}, :i))
    end

    test "recursion through the decorations of an arrow" do
      # i is contravariant: neither of wa and wb is below the other
      wa = rec(%{wa: ":bump or {:run, (-> term())@[none(), wa]}"}, :wa)
      wb = rec(%{wb: ":bump or :tick or {:run, (-> term())@[none(), wb]}"}, :wb)
      refute subtype?(wa, wb)
      refute subtype?(wb, wa)
      # o is covariant
      oa = rec(%{oa: ":bump or {:run, (-> term())@[oa, term()]}"}, :oa)
      ob = rec(%{ob: ":bump or :tick or {:run, (-> term())@[ob, term()]}"}, :ob)
      assert subtype?(oa, ob)
      refute subtype?(ob, oa)
    end

    test "a negation under a constructor" do
      t = rec(%{t: "{not t}"}, :t)
      assert subtype?(tuple([a()]), t)
      refute subtype?(tuple([tuple([a()])]), t)
    end
  end

  describe "recursive types with type variables" do
    # k = {k} or x, a recursive type whose unfolding has a variable at the top level, as
    # tallying builds its recursive solutions. Each call builds its own system.
    defp knot(x) do
      recursive(%{k: fn recur -> bare_union(tuple([recur.(:k)]), x) end}) |> Map.fetch!(:k)
    end

    test "subtyping with a variable intersected with a recursive type (patch 04)" do
      x = var(:x)
      y = var(:y)
      k = knot(x)
      assert subtype?(intersection(y, k), k)
      assert subtype?(x, k)
      refute subtype?(k, x)
    end

    @tag timeout: 5_000
    test "two copies of a recursive type with a variable (patch 05)" do
      x = var(:x)
      assert subtype?(knot(x), knot(x))
    end

    @tag timeout: 5_000
    test "tallying keeps the recursive solutions that have residual variables" do
      # Every system below has the solution i = ia = term(); tallying found its
      # principal solution but discarded it, and answered that there was none.
      i = var(:i)
      ia = var(:ia)
      assert [_] = tally([{i, ia}, {tuple([ia]), i}])
      assert [_] = tally([{i, ia}, {union(atom([:bump]), tuple([pid(ia)])), i}])

      job = arrow(tuple([]), none(), ia, term())
      assert [_] = tally([{i, ia}, {union(atom([:bump]), tuple([job])), i}])
    end

    test "a variable intersected with a recursive type prints (patch 02)" do
      x = var(:x)
      me = recursive(%{me: fn recur -> pid(recur.(:me)) end}) |> Map.fetch!(:me)
      assert to_string(intersection(x, me)) == "x and (rec me. pid(me))"
    end
  end

  describe "printing" do
    test "pids and arrows read back in the syntax of annotations" do
      assert to_string(pid(a())) == "pid(:a)"
      assert to_string(pid()) == "pid()"
      assert to_string(fun()) == "fun()"

      assert to_string(arrow(integer(), a(), b(), boolean())) ==
               "(integer() -> boolean())@[:a, :b]"

      assert to_string(arrow(tuple([]), none(), term(), term())) == "(-> term())"
      assert to_string(arrow(integer(), a(), a(), boolean())) == "(integer() -> boolean()) @ :a"

      assert to_string(arrow(tuple([integer(), a()]), none(), term(), a())) ==
               "(integer(), :a -> :a)"

      assert to_string(tuple([atom([:ready]), pid(pid(a()))])) == "{:ready, pid(pid(:a))}"
    end

    test "recursive types read back with rec" do
      me = rec(%{me: "pid(me)"}, :me)
      assert to_string(me) == "rec me. pid(me)"
      assert to_string(tuple([me])) == "{rec me. pid(me)}"
    end
  end
end
