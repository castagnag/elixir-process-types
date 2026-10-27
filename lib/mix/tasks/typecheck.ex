defmodule Mix.Tasks.Typecheck do
  @shortdoc "Type-checks programs written in the language of GRAMMAR.md"
  @moduledoc """
  Type-checks the given files and prints the errors, or the annotated functions and
  the type of the main process.

      mix typecheck examples/server_decorated.exs
      mix typecheck --ground examples/server_decorated.exs
      mix typecheck --trace examples/counter.exs

  By default the decorations are inferred (GRAMMAR.md, §9); `--ground` reads an
  undecorated arrow as `@[none(), term()]`. In inference mode, `--trace` also prints
  the constraints deferred to tallying, with the line of the rule that generated them.

  Exits with status 1 when some file has an error.
  """

  use Mix.Task

  alias ProcessTypes.Types

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: [ground: :boolean, trace: :boolean]) do
      {opts, [_ | _] = paths, []} -> check(paths, opts)
      _ -> Mix.raise("usage: mix typecheck [--ground] [--trace] FILE...")
    end
  end

  defp check(paths, opts) do
    mode = if opts[:ground], do: :ground, else: :infer

    errors? =
      Enum.reduce(paths, false, fn path, errors? ->
        result = ProcessTypes.check_file(path, mode: mode)
        if opts[:trace] && mode == :infer, do: trace(result, path)
        Mix.shell().info(ProcessTypes.report(result, path))
        errors? or result.diagnostics != []
      end)

    if errors?, do: exit({:shutdown, 1})
  end

  defp trace(result, path) do
    Mix.shell().info("#{path}: #{length(result.constraints)} constraints for tallying")

    for c <- result.constraints do
      Mix.shell().info(
        "  line #{c.line || "-"}: #{Types.to_string(c.sub)} ≤ #{Types.to_string(c.sup)}"
      )
    end
  end
end
