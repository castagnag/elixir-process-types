defmodule Mix.Tasks.Typecheck do
  @shortdoc "Type-checks programs written in the language of GRAMMAR.md"
  @moduledoc """
  Type-checks the given files and prints the errors, or the annotated functions and
  the type of the main process.

      mix typecheck examples/server_decorated.exs
      mix typecheck --ground examples/server_decorated.exs
      mix typecheck --trace examples/counter.exs
      mix typecheck --reconstruct examples/recon_bank.exs

  By default the decorations are inferred (GRAMMAR.md, §9); `--ground` reads an
  undecorated arrow as `@[none(), term()]`. In inference mode, `--trace` also prints
  the constraints deferred to tallying, with the line of the rule that generated them.
  In both modes, `--experimental-split` types a branch once per summand of its refined
  type (GRAMMAR.md, §10). `--reconstruct` is inference in which a `spawn` may have no
  `$interface`: the interfaces of these `spawn`s, and that of the main process when there
  is no `$self_interface`, are reconstructed and printed (GRAMMAR.md, §11).

  Exits with status 1 when some file has an error.
  """

  use Mix.Task

  alias ProcessTypes.Types

  @impl true
  def run(args) do
    strict = [
      ground: :boolean,
      trace: :boolean,
      experimental_split: :boolean,
      reconstruct: :boolean
    ]

    case OptionParser.parse(args, strict: strict) do
      {opts, [_ | _] = paths, []} ->
        check(paths, opts)

      _ ->
        Mix.raise(
          "usage: mix typecheck [--ground | --reconstruct] [--trace] [--experimental-split] FILE..."
        )
    end
  end

  defp check(paths, opts) do
    mode =
      cond do
        opts[:ground] -> :ground
        opts[:reconstruct] -> :reconstruct
        true -> :infer
      end

    errors? =
      Enum.reduce(paths, false, fn path, errors? ->
        result =
          ProcessTypes.check_file(path, mode: mode, split: opts[:experimental_split] == true)

        if opts[:trace] && mode != :ground, do: trace(result, path)
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
