defmodule ProcessTypes.CheckerTest do
  use ExUnit.Case, async: true

  alias ProcessTypes.Types

  # The rules of Sections 3–6, with every decoration known: ground mode (GRAMMAR.md,
  # §9). Inference is tested in infer_test.exs.
  defp check(source), do: ProcessTypes.check_string(source, mode: :ground)
  defp errors(source), do: Enum.map(check(source).diagnostics, &{&1.line, &1.message})

  defp main(source),
    do:
      check(source)
      |> tap(&assert(&1.diagnostics == [], ProcessTypes.report(&1)))
      |> Map.get(:main)
      |> Types.to_string()

  defp assert_error(source, line, fragment) do
    errors = errors(source)

    assert Enum.any?(errors, fn {l, m} -> l == line and m =~ fragment end),
           inspect(errors, pretty: true)
  end

  describe "case and receive (rules t-case, t-receive)" do
    test "a case must be exhaustive" do
      assert_error(
        """
        defmodule M do
          $ (:a or :b -> integer())
          defp f(x) do
            case x do
              :a -> 1
            end
          end
        end
        """,
        4,
        "do not cover :b"
      )
    end

    test "the clauses of a function must cover its domain" do
      assert_error(
        """
        defmodule M do
          $ integer() or atom() -> integer()
          def f(x) when is_integer(x), do: x
        end
        """,
        3,
        "do not cover atom()"
      )
    end

    test "each clause must return a subtype of the codomain" do
      assert_error(
        """
        defmodule M do
          $ integer() -> atom()
          def f(x), do: x
        end
        """,
        3,
        "returns integer()"
      )
    end

    test "receive reads at the input decoration" do
      ok = """
      defmodule M do
        $ (-> integer())@[none(), {:n, integer()}]
        def f do
          receive do
            {:n, k} -> k
          end
        end
      end
      """

      assert errors(ok) == []
      assert_error(String.replace(ok, "@[none(), {:n, integer()}]", ""), 3, "returns term()")
    end

    test "a branch with an empty refined type is skipped" do
      assert main("""
             defmodule M do
               $ (boolean() -> integer())
               def f(x) do
                 case x do
                   b when is_boolean(b) -> 1
                   _ -> self() + 1
                 end
               end
             end
             M.f(true)
             """) == "integer()"
    end

    test "integer literals refine from above and are never subtracted" do
      assert main("""
             $self_interface {:n, integer()}
             receive do
               {:n, 0} -> :zero
               {:n, m} -> m
             end
             """) == ":zero or integer()"

      assert_error("x = 3\ncase x do\n  0 -> :zero\nend\n", 2, "do not cover integer()")
    end

    test "div and rem take and return integers" do
      assert main("div(7, 2) + rem(7, 2)") == "integer()"
      assert_error("div(:a, 2)", 1, "the left operand of div")
    end

    test "if follows Elixir's truthiness" do
      assert main("x = 3 < 4\nif x do :yes else :no end\n") == ":no or :yes"
      # an integer is always truthy: the else branch is skipped
      assert main("x = 3\nif x do :yes else :no end\n") == ":yes"
    end
  end

  describe "self, send and spawn (rules t-self, t-send, t-spawn)" do
    test "self() has type pid(o)" do
      source = """
      defmodule M do
        $ (-> pid(:a))@[:a, :a]
        def me, do: self()
      end
      """

      assert errors(source) == []
      assert_error(String.replace(source, "@[:a, :a]", "@[none(), :a]"), 3, "returns pid()")
      assert errors(String.replace(source, "@[:a, :a]", " @ :a")) == []
      assert errors(String.replace(source, "@[:a, :a]", " @ (:a or :b)")) == []
      assert_error(String.replace(source, "@[:a, :a]", " @ :b"), 3, "returns pid(:b)")
    end

    test "a send is checked against the interface of the target" do
      assert_error(
        """
        $self_interface :a
        send(self(), :b)
        """,
        2,
        "the target accepts :a, not :b"
      )
    end

    test "a spawned body runs at the bracket of its interface" do
      assert errors("""
             $interface {:n, integer()}
             p = spawn(fn ->
               receive do
                 {:n, k} -> k + 1
               end
             end)
             send(p, {:n, 3})
             """) == []
    end

    test "a spawn needs an interface" do
      assert_error("spawn(fn -> :ok end)\n", 1, "needs a $interface")
    end

    test "a spawned function must run at the bracket of the interface" do
      source = """
      defmodule M do
        $ (-> none())@[none(), :a]
        def loop do
          receive do
            :a -> loop()
          end
        end
      end
      $ (-> none())@[none(), :a]
      f = fn -> M.loop() end
      $interface :a
      spawn(f)
      """

      assert errors(source) == []

      assert_error(
        String.replace(source, "$interface :a", "$interface :a or :b"),
        12,
        "cannot run in a process of interface :a or :b"
      )
    end
  end

  describe "functions (rules t-abs, t-app)" do
    test "an annotated fn" do
      assert main("""
             $ integer() -> integer()
             f = fn x -> x + 1 end
             f.(3)
             """) == "integer()"
    end

    test "an fn with parameters needs an annotation" do
      assert_error("f = fn x -> x end\n", 1, "needs a $ annotation")
    end

    test "an unannotated fn without expected type is typed at [none(), term()]" do
      assert_error("f = fn -> send(self(), :x) end\n", 1, "the target accepts none(), not :x")
    end

    test "a call must be at a bracket that narrows the arrow" do
      assert_error(
        """
        defmodule M do
          $ (-> integer())@[none(), {:n, integer()}]
          def f do
            receive do
              {:n, k} -> k
            end
          end
        end
        M.f()
        """,
        9,
        "cannot be applied to {} at the bracket [term(), term()]"
      )
    end

    test "a private function is not callable from outside its module" do
      assert_error(
        """
        defmodule M do
          $ integer() -> integer()
          defp f(x), do: x
        end
        M.f(1)
        """,
        5,
        "M.f/1 is private"
      )
    end

    test "undefined names" do
      assert_error("x + 1\n", 1, "undefined variable x")
      assert_error("f(1)\n", 1, "undefined function f/1")
    end

    test "a match may fail" do
      assert_error(
        """
        $self_interface {:ok, integer()} or :error
        receive do
          m -> {:ok, v} = m
        end
        """,
        3,
        "this match may fail: :error"
      )
    end

    test "guards combine tests of one variable" do
      assert main("""
             defmodule M do
               $ (integer() or atom() or {} -> :number_or_atom or :other)
               def f(x) when is_integer(x) or is_atom(x), do: :number_or_atom
               def f(_), do: :other
             end
             M.f(1)
             """) == ":number_or_atom or :other"
    end
  end

  describe "types and annotations" do
    test "recursive type definitions: send(self(), self())" do
      result = check("$type me = pid(me)\n$self_interface me\nsend(self(), self())\n")
      assert result.diagnostics == []
      assert ProcessTypes.Printer.to_string(result.main, result.names) == "me"
    end

    test "a recursive function on a recursive type" do
      source = """
      $type list = nil or {integer(), list}
      defmodule L do
        $ list -> integer()
        def len(nil), do: 0
        def len({_, t}), do: 1 + len(t)
      end
      L.len({1, {2, nil}})
      L.len({1, {:two, nil}})
      """

      assert errors(source) == [
               {8,
                "L.len/1 cannot be applied to {integer(), {:two, nil}}: its type is (list -> integer())"}
             ]
    end

    test "recursion through the decorations of an arrow" do
      assert main("""
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
             """) == ":ok"
    end

    test "a definition recursive through or, and and not only is rejected" do
      assert_error(
        "$type t = t or integer()\n$self_interface t\n:ok\n",
        2,
        "the definition of t is not contractive: the cycle t -> t passes through no tuple, pid or arrow"
      )

      assert_error(
        "$type a = b\n$type b = a\n$self_interface a\n:ok\n",
        3,
        "the cycle a -> b -> a"
      )
    end

    test "integer singleton types are not available" do
      assert_error("$self_interface 3\n:ok\n", 1, "integer singleton types")
    end

    test "an annotation must be followed by a def or an fn" do
      assert_error("$ integer() -> integer()\n:ok\n", 1, "followed by no def or fn")
    end

    test "decorations need a parenthesized arrow" do
      assert_error("$self_interface :a@[:a, :a]\n:ok\n", 1, "must follow a parenthesized arrow")
      assert_error("$self_interface :a @ :a\n:ok\n", 1, "must follow a parenthesized arrow")
    end

    test "decorations are a pair or a single type" do
      assert_error("$self_interface (-> :a)@[:a]\n:ok\n", 1, "with two types, or @ u")
      assert_error("$self_interface (-> :a) @ :a @ :a\n:ok\n", 1, "one pair of decorations")
    end
  end
end
