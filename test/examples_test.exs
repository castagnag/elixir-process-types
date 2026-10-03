defmodule ProcessTypes.ExamplesTest do
  use ExUnit.Case, async: true

  # Each example must report errors exactly on the lines marked "# error:".

  for path <- Path.wildcard(Path.expand("../examples/*.exs", __DIR__)) do
    @path path
    test Path.basename(path) do
      source = File.read!(@path)

      expected =
        source
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> line =~ "# error:" end)
        |> Enum.map(&elem(&1, 1))

      result = ProcessTypes.check_string(source)
      lines = result.diagnostics |> Enum.map(& &1.line) |> Enum.uniq() |> Enum.sort()
      assert lines == expected, ProcessTypes.report(result, @path)
    end
  end

  test "negate has the types of Section 4.1" do
    result = ProcessTypes.check_file(Path.expand("../examples/negate.exs", __DIR__))
    assert ProcessTypes.Types.to_string(result.main) == "boolean()"
  end

  test "a job sent to a worker is typed at the bracket of its expected type" do
    result =
      ProcessTypes.check_string("""
      $type job = (-> term())@[:ping, term()]
      $interface :ping or {:run, job}
      w = spawn(fn ->
        receive do
          {:run, j} -> j.()
        end
      end)
      send(w, {:run, fn -> send(self(), :ping) end})
      """)

    assert result.diagnostics == []
    assert ProcessTypes.Types.to_string(result.main) == "{:run, (-> :ping)@[:ping, term()]}"
  end
end
