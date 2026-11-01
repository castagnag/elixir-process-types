defmodule ProcessTypes.ExamplesTest do
  use ExUnit.Case, async: true

  # Each example must report errors exactly on the lines marked "# error:", in both
  # modes (GRAMMAR.md, §9), or only in the mode named by a line "# mode: infer" or
  # "# mode: ground". The tests of an example with a line "# slow: ..." are tagged
  # :slow, and run only with mix test --include slow. An example with a line
  # "# split: experimental" is checked with the option split (GRAMMAR.md, §10).

  for path <- Path.wildcard(Path.expand("../examples/*.exs", __DIR__)),
      source = File.read!(path),
      mode <- [:ground, :infer],
      not (source =~ ~r/^# mode: (infer|ground)$/m) or source =~ "# mode: #{mode}\n" do
    @path path
    @mode mode
    @tag slow: source =~ ~r/^# slow:/m
    test "#{Path.basename(path)}, #{mode}" do
      source = File.read!(@path)

      expected =
        source
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> line =~ "# error:" end)
        |> Enum.map(&elem(&1, 1))

      split = source =~ ~r/^# split: experimental$/m
      result = ProcessTypes.check_string(source, mode: @mode, split: split)
      lines = result.diagnostics |> Enum.map(& &1.line) |> Enum.uniq() |> Enum.sort()
      assert lines == expected, ProcessTypes.report(result, @path)
    end
  end

  test "counter of Section 4.1 is callable at :total by the client, in both modes" do
    # The example without its error lines, and without the annotation of mixed.
    lines = Path.expand("../examples/counter.exs", __DIR__) |> File.read!() |> String.split("\n")
    mixed = Enum.find_index(lines, &(&1 =~ "def mixed"))

    source =
      lines
      |> List.delete_at(mixed - 1)
      |> Enum.reject(&(&1 =~ "# error:"))
      |> Enum.join("\n")

    for mode <- [:ground, :infer] do
      result = ProcessTypes.check_string(source, mode: mode)
      assert result.diagnostics == [], ProcessTypes.report(result, "counter.exs")
      assert ProcessTypes.Types.to_string(result.main) == "integer()"
    end
  end

  test "in ground mode, a job sent to a worker is typed at the bracket of its expected type" do
    result =
      ProcessTypes.check_string(
        """
        $type job = (-> term())@[:ping, term()]
        $interface :ping or {:run, job}
        w = spawn(fn ->
          receive do
            {:run, j} -> j.()
          end
        end)
        send(w, {:run, fn -> send(self(), :ping) end})
        """,
        mode: :ground
      )

    assert result.diagnostics == []
    assert ProcessTypes.Types.to_string(result.main) == "{:run, (-> :ping)@[:ping, term()]}"
  end
end
