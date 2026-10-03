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

  test "decorations are printed with names" do
    arrow = Types.arrow(Types.tuple([]), w(), Types.term(), Types.atom([:a]))
    assert show(arrow) == "(-> :a)@[w, term()]"
  end

  test "the messages of Section 2 name the interfaces" do
    result = ProcessTypes.check_file(Path.expand("../examples/dispatcher_errors.exs", __DIR__))
    messages = Map.new(result.diagnostics, &{&1.line, &1.message})
    assert messages[53] == "send: the target accepts Server.worker, not {:wrk_add, integer()}"
    assert messages[55] == "send: the target accepts Server.job_writes, not :tick"
    assert messages[56] == "the left operand of + has type Server.job_reads, not integer()"
  end
end
