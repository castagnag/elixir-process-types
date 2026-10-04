defmodule ProcessTypes.TypeGraphTest do
  use ExUnit.Case, async: true

  alias ProcessTypes.{Annotations, TypeGraph, TypeSyntax, Types}

  # Annotations, parsed as in annotation lines.
  defp parse(source) do
    {:ok, t} = Annotations.parse_type(source)
    t
  end

  @defs %{
    {nil, :job} => {{:arrow, [], :term, nil}, 1},
    # sigma = (integer() -> sigma)
    {nil, :sigma} => {{:arrow, [:integer], {:name, nil, :sigma}, nil}, 2}
  }

  defp decorate(source, prefix \\ "x") do
    {:ok, t, minted} = TypeGraph.decorate(parse(source), @defs, nil, prefix)
    {t, minted}
  end

  describe "the decoration @ u (GRAMMAR.md, §5.1)" do
    test "it is @[u, u], binds tighter than or, and is printed back" do
      assert parse("(-> :a) @ :b") == parse("(-> :a)@[:b, :b]")
      assert parse("(-> :a) @ :b or :c") == parse("(-> :a)@[:b, :b] or :c")
      assert parse("(-> :a) @ (:b or :c)") == parse("(-> :a)@[:b or :c, :b or :c]")
      assert parse("(-> :a) @ (-> :b)") == parse("(-> :a)@[(-> :b), (-> :b)]")

      for source <- ["(-> :a) @ (:b or :c)", "(-> :a) @ (not :b)", "(-> :a) @ ((-> :b) @ :c)"] do
        assert TypeSyntax.to_string(parse(source)) == source
      end
    end
  end

  describe "decorate(·) (Definition def:decorate)" do
    test "equal arrow annotations of an occurrence share their decorations" do
      {t, minted} = decorate("{(-> term()), (-> term()), job, (-> integer())}")
      # two classes: (-> term()), written twice or named job, and (-> integer())
      assert length(minted) == 4

      assert Types.to_string(t) ==
               "{(-> term())@[o_x_a1, i_x_a1], (-> term())@[o_x_a1, i_x_a1], " <>
                 "(-> term())@[o_x_a1, i_x_a1], (-> integer())@[o_x_a2, i_x_a2]}"
    end

    test "written decorations are kept" do
      {t, _} = decorate("{(-> term())@[:a, :b], (-> term())}")
      assert Types.to_string(t) == "{(-> term())@[:a, :b], (-> term())@[o_x_a1, i_x_a1]}"
    end

    test "a recursive annotation gets a regular decoration" do
      {t, minted} = decorate("sigma")
      assert [{o, :o}, {i, :i}] = minted
      assert Types.equal?(t, Types.arrow(Types.integer(), o, i, t))
    end

    test "two occurrences are decorated independently" do
      {t1, _} = decorate("job", "p")
      {t2, _} = decorate("job", "q")
      refute Types.equal?(t1, t2)
    end

    test "each top-level arrow of a function annotation gets a pair of its own (i-abs)" do
      {:ok, [a1, a2], minted} =
        TypeGraph.decorate_arrows(
          parse("(integer() -> integer()) and (atom() -> atom())"),
          @defs,
          nil,
          "f"
        )

      assert length(minted) == 4
      refute Types.equal?(a1.o, a2.o)
      refute Types.equal?(a1.i, a2.i)
    end

    test "the codomain of a top-level arrow is decorated with the classes" do
      {:ok, [arrow], _} = TypeGraph.decorate_arrows({:name, nil, :sigma}, @defs, nil, "f")
      assert Types.equal?(arrow.s, Types.integer())
      # the codomain is sigma, decorated at the pair of its class, not at the pair of
      # the top-level arrow
      refute Types.equal?(arrow.t, Types.arrow(Types.integer(), arrow.o, arrow.i, arrow.t))
    end
  end
end
