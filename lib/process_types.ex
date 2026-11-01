defmodule ProcessTypes do
  @moduledoc """
  A prototype type checker for Elixir processes (Sections 3–6 of the paper, with the
  inference of decorations of Section 8).

  The accepted language is specified in `GRAMMAR.md`, the design in `README.md`.
  `check_string/1` parses a program (`ProcessTypes.Frontend`) and checks it
  (`ProcessTypes.Checker`).
  """

  alias ProcessTypes.{Checker, Diagnostic, Frontend, TypeSyntax}
  alias ProcessTypes.Checker.Result

  @doc """
  Checks a program given as a string. Options are those of `ProcessTypes.Checker.check/2`:
  `mode: :infer` (the default) or `mode: :ground` (GRAMMAR.md, §9), and `split: true`
  (experimental, GRAMMAR.md, §10).
  """
  def check_string(source, opts \\ []) do
    case Frontend.parse(source) do
      {nil, diagnostics} ->
        %Result{diagnostics: diagnostics, mode: Keyword.get(opts, :mode, :infer)}

      {program, diagnostics} ->
        result = Checker.check(program, opts)
        %{result | diagnostics: Enum.sort_by(diagnostics ++ result.diagnostics, & &1.line)}
    end
  end

  @doc "Checks the program in a file."
  def check_file(path, opts \\ []), do: path |> File.read!() |> check_string(opts)

  @doc "A human-readable report of a result."
  def report(%Result{} = result, file \\ "nofile") do
    case result.diagnostics do
      [] ->
        functions =
          Enum.map(result.functions, &"  #{&1.name} : #{TypeSyntax.to_string(&1.annotation)}")

        main =
          if result.main,
            do: ["  main process : #{ProcessTypes.Printer.to_string(result.main, result.names)}"],
            else: []

        Enum.join(["#{file}: ok" | functions ++ main], "\n")

      diagnostics ->
        Enum.map_join(diagnostics, "\n", &Diagnostic.format(&1, file))
    end
  end
end
