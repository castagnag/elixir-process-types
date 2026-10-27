defmodule ProcessTypes.TypeSyntax do
  @moduledoc """
  Types as written in annotations (GRAMMAR.md, §5), and their meaning.

  A source type is one of

      {:atom, a}                       a singleton type :a, true, false, nil
      :integer | :atom | :boolean | :tuple | :term | :none | :fun
      {:pid, t}                        pid(t); pid() is {:pid, :none}
      {:tuple, [t]}                    {t1, ..., tn}
      {:arrow, [t], t, {o, i} | nil}   (t1, ..., tn -> t)@[o, i]; nil is @[none(), term()]
                                       (t1, ..., tn -> t) @ u is @[u, u]
      {:or, t, t} | {:and, t, t} | {:not, t}
      {:name, module | nil, name}      a type defined by $type
      {:raw, quoted}                   only when printing a type that has no source form

  and, only in printed types, `{:rec, x, t}` (the recursive type x = t, printed
  `rec x. t`), `{:recvar, x}` (an occurrence of x in t) and `{:var, x}` (a type
  variable).

  The arguments of an arrow are a list: the domain is the argument itself for one
  argument, and the tuple of the arguments otherwise (GRAMMAR.md, §5.2).
  """

  import Kernel, except: [to_string: 1]

  @builtins %{
    integer: :integer,
    atom: :atom,
    boolean: :boolean,
    tuple: :tuple,
    term: :term,
    none: :none,
    fun: :fun
  }

  # Parsing

  @doc "Reads the Elixir quoted form of an annotation type."
  def from_quoted(q) do
    {:ok, parse(q)}
  catch
    {:type_syntax, message} -> {:error, message}
  end

  defp parse(a) when is_atom(a), do: {:atom, a}
  defp parse(n) when is_integer(n), do: no_integer_singletons(n)
  defp parse({:-, _, [n]}) when is_integer(n), do: no_integer_singletons(-n)
  defp parse({:pid, _, []}), do: {:pid, :none}
  defp parse({:pid, _, [t]}), do: {:pid, parse(t)}
  defp parse({name, _, []}) when is_map_key(@builtins, name), do: Map.fetch!(@builtins, name)
  defp parse({:{}, _, elems}), do: {:tuple, Enum.map(elems, &parse/1)}
  defp parse({a, b}), do: {:tuple, [parse(a), parse(b)]}
  defp parse([{:->, _, [args, ret]}]), do: {:arrow, Enum.map(args, &parse/1), parse(ret), nil}
  defp parse({:or, _, [a, b]}), do: {:or, parse(a), parse(b)}
  defp parse({:and, _, [a, b]}), do: {:and, parse(a), parse(b)}
  defp parse({:not, _, [a]}), do: {:not, parse(a)}
  defp parse({:__block__, _, [q]}), do: parse(q)

  # `@[o, i]` and `@ u`, rewritten as `~>`. The quoted form of an arrow is a list of one
  # `->`, so `@ (-> t)` is told from `@[o, i]` by its element.
  defp parse({:~>, _, [arrow, decorations]}) do
    case {parse(arrow), decorations} do
      {{:arrow, args, ret, nil}, [o, i]} ->
        {:arrow, args, ret, {parse(o), parse(i)}}

      {{:arrow, args, ret, nil}, [{:->, _, _}] = u} ->
        {:arrow, args, ret, same(parse(u))}

      {{:arrow, args, ret, nil}, u} when not is_list(u) ->
        {:arrow, args, ret, same(parse(u))}

      {{:arrow, _, _, nil}, _} ->
        bad("decorations are written @[o, i], with two types, or @ u")

      {{:arrow, _, _, _}, _} ->
        bad("an arrow carries one pair of decorations")

      _ ->
        bad("@[o, i] or @ u must follow a parenthesized arrow")
    end
  end

  defp parse({name, _, context}) when is_atom(name) and is_atom(context), do: {:name, nil, name}

  defp parse({{:., _, [{:__aliases__, _, parts}, name]}, _, []}) when is_atom(name),
    do: {:name, Module.concat(parts), name}

  defp parse({name, _, args}) when is_atom(name) and is_list(args),
    do: bad("unknown type #{name}/#{length(args)}")

  defp parse(q), do: bad("not a type: #{Macro.to_string(q)}")

  defp no_integer_singletons(n),
    do:
      bad(
        "integer singleton types such as #{n} are not available (Descr has none): use integer()"
      )

  defp same(u), do: {u, u}

  defp bad(message), do: throw({:type_syntax, message})

  # Meaning

  @doc """
  The Descr type denoted by `t`. Type names are resolved in `defs`, which maps
  `{module | nil, name}` to `{source_type, line}`; a bare name in the scope of a
  module is first looked up in that module. Definitions may be recursive, if
  contractive (`ProcessTypes.TypeGraph`).
  """
  defdelegate to_descr(t, defs, scope), to: ProcessTypes.TypeGraph

  @doc """
  The arrows of a function annotation `L` (GRAMMAR.md, §5.1): a list of maps with the
  arity, the domain `s`, the decorations `o` and `i`, the codomain `t`, and the source.
  """
  defdelegate arrows(t, defs, scope), to: ProcessTypes.TypeGraph

  # Printing

  @doc "Prints a source type in the syntax of annotations."
  def to_string(t), do: show(t, 0)

  @doc """
  The type `t` with the decorations of its arrows removed, for display only: the result
  prints undecorated arrows, which do not mean `@[none(), term()]` here. Operands of a
  union or an intersection that become equal are merged.
  """
  def erase_decorations({:rec, x, t}), do: {:rec, x, erase_decorations(t)}
  def erase_decorations({:or, a, b}), do: merge(:or, erase_decorations(a), erase_decorations(b))
  def erase_decorations({:and, a, b}), do: merge(:and, erase_decorations(a), erase_decorations(b))
  def erase_decorations({:not, a}), do: {:not, erase_decorations(a)}
  def erase_decorations({:tuple, ts}), do: {:tuple, Enum.map(ts, &erase_decorations/1)}
  def erase_decorations({:pid, :none} = p), do: p
  def erase_decorations({:pid, t}), do: {:pid, erase_decorations(t)}

  def erase_decorations({:arrow, args, ret, _}),
    do: {:arrow, Enum.map(args, &erase_decorations/1), erase_decorations(ret), nil}

  def erase_decorations(t), do: t

  defp merge(_, a, a), do: a
  defp merge(op, a, b), do: {op, a, b}

  # Precedence: rec 0, or 1, and 2, not 3, atomic 4. The body of rec extends as far
  # to the right as possible.
  defp show({:rec, x, t}, p), do: paren(p > 0, "rec #{x}. #{show(t, 0)}")
  defp show({:recvar, x}, _), do: Atom.to_string(x)
  defp show({:var, x}, _), do: Atom.to_string(x)
  defp show({:or, a, b}, p), do: paren(p > 1, "#{show(a, 1)} or #{show(b, 1)}")
  defp show({:and, a, b}, p), do: paren(p > 2, "#{show(a, 2)} and #{show(b, 2)}")
  defp show({:not, a}, p), do: paren(p > 3, "not #{show(a, 3)}")
  defp show({:atom, a}, _), do: inspect(a)
  defp show({:pid, :none}, _), do: "pid()"
  defp show({:pid, t}, _), do: "pid(#{show(t, 0)})"
  defp show({:tuple, ts}, _), do: "{" <> Enum.map_join(ts, ", ", &show(&1, 0)) <> "}"

  defp show({:arrow, args, ret, decorations}, _) do
    args = if args == [], do: "", else: Enum.map_join(args, ", ", &show(&1, 0)) <> " "
    arrow = "(" <> args <> "-> " <> show(ret, 0) <> ")"

    case decorations do
      nil -> arrow
      {u, u} -> arrow <> " @ " <> paren(match?({:arrow, _, _, {_, _}}, u), show(u, 4))
      {o, i} -> arrow <> "@[" <> show(o, 0) <> ", " <> show(i, 0) <> "]"
    end
  end

  defp show({:name, nil, name}, _), do: Atom.to_string(name)
  defp show({:name, module, name}, _), do: "#{inspect(module)}.#{name}"
  defp show({:raw, q}, _), do: Macro.to_string(q)
  defp show(name, _) when is_atom(name), do: "#{name}()"

  defp paren(true, s), do: "(" <> s <> ")"
  defp paren(false, s), do: s
end
