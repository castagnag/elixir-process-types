defmodule ProcessTypes.ExamplesTest do
  use ExUnit.Case, async: true

  # Each example must report errors exactly on the lines marked "# error:", in both
  # modes (GRAMMAR.md, §9), or only in the mode named by a line "# mode: infer" or
  # "# mode: ground". The tests of an example with a line "# slow: ..." are tagged
  # :slow, and run only with mix test --include slow.

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

      result = ProcessTypes.check_string(source, mode: @mode)
      lines = result.diagnostics |> Enum.map(& &1.line) |> Enum.uniq() |> Enum.sort()
      assert lines == expected, ProcessTypes.report(result, @path)
    end
  end

  test "negate has the types of Section 4.1, in both modes" do
    path = Path.expand("../examples/negate.exs", __DIR__)

    for mode <- [:ground, :infer] do
      result = ProcessTypes.check_file(path, mode: mode)
      assert ProcessTypes.Types.to_string(result.main) == "boolean()"
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
