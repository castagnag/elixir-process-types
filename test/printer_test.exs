defmodule ProcessTypes.PrinterTest do
  use ExUnit.Case, async: true

  alias ProcessTypes.{Printer, Types}

  # $type w = :a or {:b, integer()}       (top level)
  # $type v = {:v, w}                     (in module M)
  # $type stop = :stop                    (top level)
  @defs %{
    {nil, :w} => {{:or, {:atom, :a}, {:tuple, [{:atom, :b}, :integer]}}, 1},
    {M, :v} => {{:tuple, [{:atom, :v}, {:name, nil, :w}]}, 2},
    {nil, :stop} => {{:atom, :stop}, 3}
  }

  defp w, do: Types.union(Types.atom([:a]), Types.tuple([Types.atom([:b]), Types.integer()]))
  defp show(t, scope \\ nil), do: Printer.to_string(t, Printer.names(@defs, scope))

  test "a type equal to a name is printed as the name" do
    assert show(w()) == "w"
    assert show(Types.tuple([Types.atom([:x]), w()])) == "{:x, w}"
    assert show(Types.pid(w())) == "pid(w)"
  end

  test "in a union, a name replaces the disjuncts whose union it denotes" do
    assert show(Types.union(w(), Types.atom([:c]))) == "w or :c"
    assert show(Types.union(Types.atom([:a]), Types.atom([:c]))) == ":a or :c"
  end

  test "names of other modules are qualified" do
    v = Types.tuple([Types.atom([:v]), w()])
    assert show(v) == "M.v"
    assert show(v, M) == "v"
  end

  test "singleton types are not renamed" do
    assert show(Types.atom([:stop])) == ":stop"
  end

  test "a recursive type equal to a name is printed as the name" do
    # $type list = nil or {integer(), list}
    defs =
      Map.put(@defs, {nil, :list}, {
        {:or, {:atom, nil}, {:tuple, [:integer, {:name, nil, :list}]}},
        4
      })

    {:ok, list} = ProcessTypes.TypeSyntax.to_descr({:name, nil, :list}, defs, nil)
    names = Printer.names(defs, nil)
    assert Printer.to_string(list, names) == "list"
    assert Printer.to_string(Types.tuple([Types.integer(), list]), names) == "{integer(), list}"
    assert Printer.to_string(list) == "rec list. nil or {integer(), list}"
  end

  test "a type whose complement has fewer kinds is printed as not its complement" do
    job = Types.arrow(Types.tuple([]), Types.none(), Types.term(), Types.term())

    bad =
      Types.union(
        Types.tuple([Types.atom([:add]), Types.negation(Types.integer())]),
        Types.tuple([Types.atom([:run]), Types.negation(job)])
      )

    # Descr's own negated form, which applies first when there are no positive tuples
    assert show(Types.negation(bad)) ==
             "not {:add, not integer()} and not {:run, not (-> term())}"

    assert show(
             Types.union(Types.negation(bad), Types.tuple([Types.atom([:add]), Types.atom([:x])]))
           ) ==
             "not ({:add, not :x and not integer()} or {:run, not (-> term())})"

    assert show(Types.difference(Types.term(), Types.atom([:a]))) == "not :a"
    assert show(Types.union(Types.atom([:a]), Types.integer())) == ":a or integer()"
  end

  test "negated tuples are absorbed into the component they restrict, or dropped" do
    add = Types.tuple([Types.atom([:add]), Types.term()])
    add_int = Types.tuple([Types.atom([:add]), Types.integer()])
    run = Types.tuple([Types.atom([:run]), Types.term()])
    assert show(Types.difference(add, add_int)) == "{:add, not integer()}"
    assert show(Types.difference(add, run)) == "{:add, term()}"
  end

  test "decorations are printed with names" do
    arrow = Types.arrow(Types.tuple([]), w(), Types.term(), Types.atom([:a]))
    assert show(arrow) == "(-> :a)@[w, term()]"
  end

  test "the messages of Section 2 name the interfaces" do
    path = Path.expand("../examples/server_errors.exs", __DIR__)
    result = ProcessTypes.check_file(path, mode: :ground)
    messages = Map.new(result.diagnostics, &{&1.line, &1.message})

    # The lines marked "error:", in order.
    [first, _, third, fourth] =
      for {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ "# error:",
          do: n

    assert messages[first] == "send: the target accepts Server.worker, not {:wrk_add, integer()}"
    assert messages[third] == "send: the target accepts Server.job_writes, not :tick"
    assert messages[fourth] == "the left operand of + has type Server.worker, not integer()"
  end
end
