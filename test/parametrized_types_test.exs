defmodule ProcessTypes.ParametrizedTypesTest do
  use ExUnit.Case, async: true

  alias ProcessTypes.{Annotations, Frontend, Printer, TypeGraph, TypeSyntax, Types}

  # Type definitions with parameters (GRAMMAR.md, §5.3).

  defp program(source) do
    {program, diagnostics} = Frontend.parse(source)
    {program, Enum.map(diagnostics, &{&1.line, &1.message})}
  end

  defp meaning(text, source, scope \\ nil) do
    {program, []} = program(source)
    {:ok, t} = Annotations.parse_type(text)
    {:ok, descr} = TypeSyntax.to_descr(t, program.types, scope)
    descr
  end

  defp errors(source, mode \\ :ground) do
    ProcessTypes.check_string(source, mode: mode).diagnostics |> Enum.map(&{&1.line, &1.message})
  end

  describe "an instance is the body with the arguments in place of the parameters" do
    test "recursive definitions" do
      source = """
      $type list(a)    = nil or {a, list(a)}
      $type ints       = nil or {integer(), ints}
      $type swap(a, b) = nil or {a, swap(b, a)}
      $type sx         = nil or {:x, sy}
      $type sy         = nil or {:y, sx}
      :ok
      """

      assert Types.equal?(meaning("list(integer())", source), meaning("ints", source))
      assert Types.equal?(meaning("swap(:x, :y)", source), meaning("sx", source))
      refute Types.equal?(meaning("list(:a)", source), meaning("list(:b)", source))
      refute Types.empty?(meaning("list(list(:a))", source))
    end

    test "decorations and arrows" do
      source = """
      $type cap(o, i) = (-> term())@[o, i]
      $type both(u)   = (-> term()) @ u
      :ok
      """

      assert Types.equal?(
               meaning("cap(:a, :b)", source),
               meaning("(-> term())@[:a, :b]", source)
             )

      assert Types.equal?(meaning("both(:a)", source), meaning("cap(:a, :a)", source))
    end

    test "a function annotation may be an instance" do
      assert [{8, _}] =
               errors("""
               defmodule M do
                 $type endo(a) = (a -> a)@[none(), term()]

                 $ endo(integer())
                 def f(x), do: x + 1

                 $ endo(integer())
                 def g(_x), do: :a
               end
               """)
    end

    test "an interface may be an instance, in both modes" do
      source = """
      $type request(c, r) = {c, pid(r)}
      $self_interface :ok
      $interface request(:get, :ok)
      p = spawn(fn ->
        receive do
          {:get, w} -> send(w, :ok)
        end
      end)
      send(p, {:get, self()})
      send(p, {:put, self()})
      """

      for mode <- [:ground, :infer] do
        assert [{10, _}] = errors(source, mode)
      end
    end
  end

  describe "scopes" do
    @modules """
    defmodule M do
      $type x    = :m_x
      $type p(a) = {a, x}
    end
    defmodule N do
      $type x = :n_x
    end
    :ok
    """

    test "the names of an argument are those of the instance, the others of the definition" do
      assert Types.equal?(meaning("M.p(x)", @modules, N), meaning("{:n_x, :m_x}", @modules, N))
      assert Types.equal?(meaning("M.p(x)", @modules, M), meaning("{:m_x, :m_x}", @modules, M))
    end

    test "a parameter hides a type of the same name" do
      source = """
      $type c      = :global
      $type w(c)   = pid(c)
      $type y(z)   = {z, c}
      :ok
      """

      assert Types.equal?(meaning("w(:mine)", source), meaning("pid(:mine)", source))
      assert Types.equal?(meaning("y(c)", source), meaning("{:global, :global}", source))
    end
  end

  describe "wrong definitions and instances" do
    test "the number of arguments" do
      source = """
      $type one(a)    = {a}
      $type two(a, b) = {a, b}
      $self_interface LINE
      :ok
      """

      with_type = &String.replace(source, "LINE", &1)

      assert [{3, "the type one takes 1 argument, not 2"}] = errors(with_type.("one(:a, :b)"))
      assert [{3, "the type two takes 2 arguments, not 1"}] = errors(with_type.("two(:a)"))
      assert [{3, "the type one takes 1 argument, not 0"}] = errors(with_type.("one"))
      assert [{3, "unknown type nope"}] = errors(with_type.("nope(:a)"))

      assert [{3, "the type plain takes 0 arguments, not 1"}] =
               errors("$type plain = :a\n\n" <> "$self_interface plain(:b)\n:ok\n")
    end

    test "a parameter takes no arguments" do
      assert [{2, "unknown type g"}] = errors("$type f(g) = g(:a)\n$self_interface f(:b)\n:ok\n")
    end

    test "the form of a definition" do
      for {definition, message} <- [
            {"$type f() = :a", "one or more distinct names"},
            {"$type f(a, a) = a", "one or more distinct names"},
            {"$type f(1) = :a", "one or more distinct names"},
            {"$type f(A) = :a", "one or more distinct names"},
            {"$type pid(a) = a", "pid is a built-in type"},
            {"$type F(a) = a", "a type definition is written"}
          ] do
        assert [{1, m}] = errors(definition <> "\n:ok\n")
        assert m =~ message
      end
    end

    test "a name has one definition" do
      assert [{2, "type f is defined twice"}] = errors("$type f = :a\n$type f(a) = a\n:ok\n")
    end
  end

  describe "contractivity is a property of the instances" do
    test "through a transparent definition" do
      source = """
      $type id(a) = a
      $type me    = pid(me)
      $type good  = id(pid(good))
      :ok
      """

      assert Types.equal?(meaning("good", source), meaning("me", source))
      assert Types.equal?(meaning("id(id(:a))", source), Types.atom([:a]))
    end

    test "cycles through or, and and not only are rejected" do
      assert [{3, m}] = errors("$type id(a) = a\n$type t = id(t)\n$self_interface t\n:ok\n")
      assert m =~ "not contractive"

      assert [{3, m}] =
               errors("$type f(a) = a or {f(a)}\n$type t = f(t)\n$self_interface t\n:ok\n")

      assert m =~ "not contractive"
    end
  end

  describe "regularity" do
    # On the definitions as written: Frontend replaces those it rejects.
    defp irregular(source) do
      {_code, annotations, []} = Annotations.extract(source)

      annotations
      |> Enum.filter(&(&1.kind == :type))
      |> Map.new(&{{nil, &1.name}, {&1.type, &1.line}})
      |> TypeGraph.irregular()
    end

    test "definitions with finitely many instances" do
      for source <- [
            "$type list(a) = nil or {a, list(a)}\n:ok\n",
            "$type swap(a, b) = nil or {a, swap(b, a)}\n:ok\n",
            # the argument is closed: one more instance
            "$type lit(a) = nil or {a, lit({:x})}\n:ok\n",
            # the flow does not come back to a
            "$type f(a) = nil or {:x, g({a})}\n$type g(b) = nil or f(:y)\n:ok\n",
            # nested, but not on a cycle
            "$type l(a) = nil or {a, l(a)}\n$type m(a) = l(l(a))\n:ok\n"
          ] do
        assert irregular(source) == [], source
        assert errors(source) == [], source
      end
    end

    test "the instances of a regular definition are finitely many, and memoized" do
      {program, []} = program("$type swap(a, b) = nil or {a, swap(b, a)}\n:ok\n")
      {:ok, t} = Annotations.parse_type("swap(:x, :y)")

      assert TypeGraph.instances(t, program.types, nil) == [
               {:inst, {nil, :swap}, [{:atom, :x}, {:atom, :y}]},
               {:inst, {nil, :swap}, [{:atom, :y}, {:atom, :x}]}
             ]
    end

    test "a definition is rejected on its line, even if it is not used" do
      assert [{2, m}] = errors(":ok\n$type grow(a) = nil or {a, grow({a, a})}\n")
      assert m =~ "the definition of grow is not regular"
      assert m =~ "the parameter a"
    end

    test "uses of an irregular definition are errors, not loops" do
      source = """
      $type grow(a) = nil or {a, grow({a, a})}
      $self_interface grow(:a)
      :ok
      """

      assert [{1, _}, {2, m}] = errors(source)
      assert m =~ "the definition of grow is not regular"
    end

    test "through several definitions" do
      source = """
      $type t(a) = nil or {a, u(pid(a))}
      $type u(b) = nil or t(b)
      $self_interface u(:a)
      :ok
      """

      assert [{{nil, :t}, :a}] = irregular(source)
      assert [{1, _}, {3, _}] = errors(source)
    end

    test "syntactic growth counts, even when the meaning does not grow" do
      source = """
      $type k(a, b) = a
      $type t(x)    = nil or {x, t(k(:z, x))}
      :ok
      """

      assert [{{nil, :t}, :x}] = irregular(source)
    end

    test "a definition with an error in its body has no flow, and is an error when used" do
      source = """
      $type bad(a) = {a, bad({a}), nope}
      $self_interface bad(:a)
      :ok
      """

      assert irregular(source) == []
      assert [{2, "unknown type nope"}] = errors(source)
    end
  end

  test "decorate(·) gives one pair per class of the expanded arrows" do
    {program, []} = program("$type box(a) = (-> a)\n:ok\n")
    {:ok, t} = Annotations.parse_type("{box(:x), box(:y), box(:x)}")
    {:ok, _, minted} = TypeGraph.decorate(t, program.types, nil, "p")
    assert length(minted) == 4
  end

  describe "printing" do
    @printing """
    defmodule M do
      $type request(c, r) = {c, pid(r)}
      $type shown         = request(:get, :ok)

      $ request(:put, :ok) -> :ok
      def f(_x), do: :ok
    end

    $type request(c, r) = {:top, c, pid(r)}
    $type s = :a or :b
    $self_interface request(s, integer())
    :ok
    """

    defp printed(text, scope) do
      {program, []} = program(@printing)
      names = Printer.names(program.types, scope, program.instances)
      Printer.to_string(meaning(text, @printing, scope), names)
    end

    test "instances that the annotations reach are names" do
      assert printed("{:put, pid(:ok)}", M) == "request(:put, :ok)"
      assert printed("{:put, pid(:ok)}", nil) == "M.request(:put, :ok)"
      assert printed("{:x, {:put, pid(:ok)}}", M) == "{:x, request(:put, :ok)}"
      assert printed("{:top, s, pid(integer())}", nil) == "request(s, integer())"
    end

    test "a plain name comes before an instance" do
      assert printed("{:get, pid(:ok)}", M) == "shown"
    end

    test "the other instances are not names" do
      assert printed("{:other, pid(:ok)}", M) == "{:other, pid(:ok)}"
    end

    test "an instance hidden by a name of the scope is not used" do
      # At top level, request(s, integer()); in M, this request is another type.
      assert printed("{:top, s, pid(integer())}", M) =~ "{:top,"
    end

    test "a message uses an instance" do
      source = """
      defmodule M do
        $type request(c, r) = {c, pid(r)}

        $ request(:put, :ok), integer() -> :ok
        def f(_x, _n), do: :ok

        $ -> :ok
        def g(), do: f(:wrong, 1)
      end
      """

      assert [{8, m}] = errors(source)
      assert m =~ "request(:put, :ok)"
    end
  end
end
