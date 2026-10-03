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

  describe "printing" do
    test "pids and arrows read back in the syntax of annotations" do
      assert to_string(pid(a())) == "pid(:a)"
      assert to_string(pid()) == "pid()"
      assert to_string(fun()) == "fun()"

      assert to_string(arrow(integer(), a(), b(), boolean())) ==
               "(integer() -> boolean())@[:a, :b]"

      assert to_string(arrow(tuple([]), none(), term(), term())) == "(-> term())"

      assert to_string(arrow(tuple([integer(), a()]), none(), term(), a())) ==
               "(integer(), :a -> :a)"

      assert to_string(tuple([atom([:ready]), pid(pid(a()))])) == "{:ready, pid(pid(:a))}"
    end
  end
end
