defmodule ProcessTypes.TypeSyntax do
  @moduledoc """
  Types as written in annotations (GRAMMAR.md, §5), and their meaning.

  A source type is one of

      {:atom, a}                       a singleton type :a, true, false, nil
      :integer | :atom | :boolean | :tuple | :term | :none | :fun
      {:pid, t}                        pid(t); pid() is {:pid, :none}
      {:tuple, [t]}                    {t1, ..., tn}
      {:arrow, [t], t, {o, i} | nil}   (t1, ..., tn -> t)@[o, i]; nil is @[none(), term()]
      {:or, t, t} | {:and, t, t} | {:not, t}
      {:name, module | nil, name}      a type defined by $type
      {:raw, quoted}                   only when printing a type that has no source form

  The arguments of an arrow are a list: the domain is the argument itself for one
  argument, and the tuple of the arguments otherwise (GRAMMAR.md, §5.2).
  """

  import Kernel, except: [to_string: 1]
  alias ProcessTypes.Types

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

  defp parse({:~>, _, [arrow, decorations]}) do
    case {parse(arrow), decorations} do
      {{:arrow, args, ret, nil}, [o, i]} -> {:arrow, args, ret, {parse(o), parse(i)}}
      {{:arrow, _, _, nil}, _} -> bad("decorations are written @[o, i], with two types")
      {{:arrow, _, _, _}, _} -> bad("an arrow carries one pair of decorations")
      _ -> bad("@[o, i] must follow a parenthesized arrow")
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

  defp bad(message), do: throw({:type_syntax, message})

  # Meaning

  @doc """
  The Descr type denoted by `t`. Type names are resolved in `defs`, which maps
  `{module | nil, name}` to `{source_type, line}`; a bare name in the scope of a
  module is first looked up in that module.
  """
  def to_descr(t, defs, scope) do
    {:ok, descr(t, defs, scope, [])}
  catch
    {:type_syntax, message} -> {:error, message}
  end

  @doc """
  The arrows of a function annotation `L` (GRAMMAR.md, §5.1): a list of maps with the
  arity, the domain `s`, the decorations `o` and `i`, the codomain `t`, and the source.
  """
  def arrows(t, defs, scope) do
    {:ok, flatten(t, defs, scope, [])}
  catch
    {:type_syntax, message} -> {:error, message}
  end

  defp flatten({:and, a, b}, defs, scope, seen),
    do: flatten(a, defs, scope, seen) ++ flatten(b, defs, scope, seen)

  defp flatten({:arrow, args, ret, decorations} = source, defs, scope, seen) do
    {o, i} = decorations(decorations, defs, scope, seen)

    [
      %{
        arity: length(args),
        s: domain(args, defs, scope, seen),
        o: o,
        i: i,
        t: descr(ret, defs, scope, seen),
        source: source
      }
    ]
  end

  defp flatten({:name, _, _} = name, defs, scope, seen) do
    {key, body, scope} = resolve(name, defs, scope, seen)
    flatten(body, defs, scope, [key | seen])
  end

  defp flatten(t, _defs, _scope, _seen),
    do: bad("a function annotation is an intersection of arrows, not #{to_string(t)}")

  defp descr({:atom, a}, _, _, _), do: Types.atom([a])
  defp descr(:integer, _, _, _), do: Types.integer()
  defp descr(:atom, _, _, _), do: Types.atom()
  defp descr(:boolean, _, _, _), do: Types.boolean()
  defp descr(:tuple, _, _, _), do: Types.tuple()
  defp descr(:term, _, _, _), do: Types.term()
  defp descr(:none, _, _, _), do: Types.none()
  defp descr(:fun, _, _, _), do: Types.fun()
  defp descr({:pid, :none}, _, _, _), do: Types.pid()
  defp descr({:pid, t}, defs, scope, seen), do: Types.pid(descr(t, defs, scope, seen))

  defp descr({:tuple, ts}, defs, scope, seen),
    do: Types.tuple(Enum.map(ts, &descr(&1, defs, scope, seen)))

  defp descr({:arrow, args, ret, decorations}, defs, scope, seen) do
    {o, i} = decorations(decorations, defs, scope, seen)
    Types.arrow(domain(args, defs, scope, seen), o, i, descr(ret, defs, scope, seen))
  end

  defp descr({:or, a, b}, defs, scope, seen),
    do: Types.union(descr(a, defs, scope, seen), descr(b, defs, scope, seen))

  defp descr({:and, a, b}, defs, scope, seen),
    do: Types.intersection(descr(a, defs, scope, seen), descr(b, defs, scope, seen))

  defp descr({:not, a}, defs, scope, seen), do: Types.negation(descr(a, defs, scope, seen))

  defp descr({:name, _, _} = name, defs, scope, seen) do
    {key, body, scope} = resolve(name, defs, scope, seen)
    descr(body, defs, scope, [key | seen])
  end

  defp decorations(nil, _, _, _), do: {Types.none(), Types.term()}

  defp decorations({o, i}, defs, scope, seen),
    do: {descr(o, defs, scope, seen), descr(i, defs, scope, seen)}

  defp domain([arg], defs, scope, seen), do: descr(arg, defs, scope, seen)

  defp domain(args, defs, scope, seen),
    do: Types.tuple(Enum.map(args, &descr(&1, defs, scope, seen)))

  defp resolve({:name, module, name}, defs, scope, seen) do
    key =
      cond do
        module != nil and Map.has_key?(defs, {module, name}) -> {module, name}
        module != nil -> bad("unknown type #{inspect(module)}.#{name}")
        scope != nil and Map.has_key?(defs, {scope, name}) -> {scope, name}
        Map.has_key?(defs, {nil, name}) -> {nil, name}
        true -> bad("unknown type #{name}")
      end

    if key in seen do
      # seen is a stack: the cycle starts at the oldest occurrence of key
      cycle = seen |> Enum.reverse() |> Enum.drop_while(&(&1 != key))
      names = Enum.map_join(cycle ++ [key], " -> ", &key_to_string/1)
      bad("recursive type definitions are not supported yet: #{names}")
    end

    {body, _line} = Map.fetch!(defs, key)
    {key, body, elem(key, 0)}
  end

  defp key_to_string({nil, name}), do: Atom.to_string(name)
  defp key_to_string({module, name}), do: "#{inspect(module)}.#{name}"

  # Printing

  @doc "Prints a source type in the syntax of annotations."
  def to_string(t), do: show(t, 0)

  # Precedence: or 1, and 2, not 3, atomic 4.
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
