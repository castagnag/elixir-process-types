defmodule Mix.Tasks.Typecheck do
  @shortdoc "Type-checks programs written in the language of GRAMMAR.md"
  @moduledoc """
  Type-checks the given files and prints the errors, or the annotated functions and
  the type of the main process.

      mix typecheck examples/dispatcher.exs

  Exits with status 1 when some file has an error.
  """

  use Mix.Task

  @impl true
  def run([]), do: Mix.raise("usage: mix typecheck FILE...")

  def run(paths) do
    errors? =
      Enum.reduce(paths, false, fn path, errors? ->
        result = ProcessTypes.check_file(path)
        Mix.shell().info(ProcessTypes.report(result, path))
        errors? or result.diagnostics != []
      end)

    if errors?, do: exit({:shutdown, 1})
  end
end
