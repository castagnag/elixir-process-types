defmodule ProcessTypes.Annotations do
  @moduledoc """
  The annotation lines of a program (GRAMMAR.md, §1).

  `extract/1` parses every annotation line and replaces it by a blank line, so that
  what remains is Elixir code with the original line numbers.
  """

  alias ProcessTypes.{Diagnostic, TypeSyntax}

  defmodule Annotation do
    @moduledoc """
    An annotation: its `kind` (`:type`, `:fun`, `:interface` or `:self_interface`),
    the `name` it defines (for `:type`), its source `type`, the lines it spans, and
    for `:fun` and `:interface` the `target` line it attaches to.
    """
    defstruct [:kind, :name, :type, :line, :last_line, :target]
  end

  @doc "Returns `{code, annotations, diagnostics}`."
  def extract(source) do
    lines = source |> String.split(~r/\r?\n/) |> List.to_tuple()
    {spans, diagnostics} = spans(lines, 0, [], [])

    annotated =
      Enum.reduce(spans, MapSet.new(), fn {_, first, last}, acc -> Enum.into(first..last, acc) end)

    {annotations, diagnostics} =
      Enum.reduce(spans, {[], diagnostics}, fn {text, first, last}, {anns, diags} ->
        case parse(text) do
          {:ok, kind, name, type} ->
            target = if kind in [:fun, :interface], do: next_code_line(lines, last + 1, annotated)

            ann = %Annotation{
              kind: kind,
              name: name,
              type: type,
              line: first + 1,
              last_line: last + 1,
              target: target
            }

            if kind in [:fun, :interface] and target == nil,
              do:
                {anns,
                 [Diagnostic.error(first + 1, "this annotation is followed by no code") | diags]},
              else: {[ann | anns], diags}

          {:error, message} ->
            {anns, [Diagnostic.error(first + 1, message) | diags]}
        end
      end)

    code =
      for {line, index} <- Enum.with_index(Tuple.to_list(lines)) do
        if index in annotated, do: "", else: line
      end
      |> Enum.join("\n")

    {code, Enum.reverse(annotations), Enum.reverse(diagnostics)}
  end

  # The spans {text, first_index, last_index} of the annotations, continuation lines
  # included (0-based indices).
  defp spans(lines, index, spans, diags) when index >= tuple_size(lines),
    do: {Enum.reverse(spans), diags}

  defp spans(lines, index, spans, diags) do
    line = lines |> elem(index) |> String.trim_leading()

    if String.starts_with?(line, "$") do
      {text, last} = continue(lines, strip_comment(line), index)
      spans(lines, last + 1, [{text, index, last} | spans], diags)
    else
      spans(lines, index + 1, spans, diags)
    end
  end

  defp continue(lines, text, index) do
    next = index + 1

    if next < tuple_size(lines) and continuation?(text, elem(lines, next)) do
      continue(lines, text <> " " <> strip_comment(elem(lines, next)), next)
    else
      {text, index}
    end
  end

  defp continuation?(text, next) do
    next = strip_comment(next)

    not String.starts_with?(next, "$") and
      (open_brackets(text) > 0 or Regex.match?(~r/^(or|and)\b/, next))
  end

  defp open_brackets(text) do
    text
    |> String.graphemes()
    |> Enum.reduce(0, fn
      c, n when c in ["(", "[", "{"] -> n + 1
      c, n when c in [")", "]", "}"] -> n - 1
      _, n -> n
    end)
  end

  defp strip_comment(line), do: line |> String.split("#", parts: 2) |> hd() |> String.trim()

  defp next_code_line(lines, index, _annotated) when index >= tuple_size(lines), do: nil

  defp next_code_line(lines, index, annotated) do
    if index in annotated or strip_comment(elem(lines, index)) == "",
      do: next_code_line(lines, index + 1, annotated),
      else: index + 1
  end

  # Parsing one annotation

  defp parse(text) do
    cond do
      match = Regex.run(~r/^\$type\s+([a-z_][a-zA-Z0-9_]*)\s*=(.*)$/s, text) ->
        [_, name, body] = match
        with {:ok, type} <- parse_type(body), do: {:ok, :type, String.to_atom(name), type}

      String.starts_with?(text, "$type") ->
        {:error, "a type definition is written $type name = T"}

      match = Regex.run(~r/^\$self_interface\b(.*)$/s, text) ->
        with {:ok, type} <- parse_type(Enum.at(match, 1)), do: {:ok, :self_interface, nil, type}

      match = Regex.run(~r/^\$interface\b(.*)$/s, text) ->
        with {:ok, type} <- parse_type(Enum.at(match, 1)), do: {:ok, :interface, nil, type}

      match = Regex.run(~r/^\$(?=[\s(])(.*)$/s, text) ->
        with {:ok, type} <- parse_type(Enum.at(match, 1)), do: {:ok, :fun, nil, type}

      true ->
        {:error, "unknown annotation: #{text}"}
    end
  end

  @doc """
  Parses the type of an annotation (GRAMMAR.md, §1): `@` is rewritten as `~>`, so that
  `(s -> t)@[o, i]` and `(s -> t) @ u` are Elixir code, and the type is parenthesized.
  """
  def parse_type(text) do
    text = String.trim(text)

    if text == "" do
      {:error, "the annotation has no type"}
    else
      code = "(" <> Regex.replace(~r/\s*@\s*/, text, " ~> ") <> ")"

      case Code.string_to_quoted(code) do
        {:ok, quoted} -> TypeSyntax.from_quoted(quoted)
        {:error, _} -> {:error, "cannot parse the type #{text}"}
      end
    end
  end
end
