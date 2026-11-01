defmodule ProcessTypes.Printer do
  @moduledoc """
  Printing types with the names that `$type` defines.

  A type is read back from Descr into the syntax of annotations
  (`ProcessTypes.Types.to_syntax/1`), after its equivalent recursive nodes are merged
  (`ProcessTypes.Types.factorize/1`). Then every compound subterm that denotes the same
  type as a defined name is printed as that name, and in a union a name also replaces
  the disjuncts whose union it denotes; larger names are tried first. Singleton types
  and built-in types are never renamed. A definition with parameters has no type: what
  gets a name is each of its instances that the annotations of the program reach.
  """

  alias ProcessTypes.{TypeGraph, TypeSyntax, Types}

  @doc """
  The names visible in `scope` (a module, or `nil` for the top level), as a list of
  `{name, type}` pairs, where `name` is the source type that prints the name: `n` for
  a name of the scope or of the top level, `M.n` for a name of another module; those of
  the scope come first. They are followed by the `instances`
  (`ProcessTypes.Frontend.Program`), those written in `scope` first, printed in the same
  way.
  """
  def names(defs, scope, instances \\ []) do
    plain =
      defs
      |> Enum.sort_by(fn {{module, _}, {_type, line}} -> {module != scope, line} end)
      |> Enum.map(fn {{module, n} = key, _} -> {{:inst, key, []}, {:name, module, n}} end)

    instances =
      instances
      |> Enum.sort_by(fn {module, _} -> module != scope end)
      |> Enum.uniq_by(&elem(&1, 1))
      |> Enum.map(fn {_, inst} -> {inst, inst} end)

    (plain ++ instances)
    |> Enum.flat_map(fn {closed, source} ->
      with {:ok, name} <- display(closed, defs, scope),
           {:ok, t} <- TypeSyntax.to_descr(source, defs, nil),
           false <- Types.empty?(t) or Types.equal?(t, Types.term()) do
        [{name, t}]
      else
        _ -> []
      end
    end)
    # stable: names of the same size keep the order above
    |> Enum.sort_by(fn {_, t} -> -size(t) end)
  end

  # How a closed name or instance is written in scope; :error if a name of scope hides
  # it or one of its arguments.
  defp display(closed, defs, scope) do
    {:ok, written(closed, defs, scope)}
  catch
    :hidden -> :error
  end

  defp written({:inst, {module, n}, args}, defs, scope) do
    args = Enum.map(args, &written(&1, defs, scope))

    module =
      cond do
        module == scope -> nil
        module == nil and Map.has_key?(defs, {scope, n}) -> throw(:hidden)
        true -> module
      end

    if args == [], do: {:name, module, n}, else: {:app, module, n, args}
  end

  defp written(t, defs, scope), do: TypeGraph.map_children(t, &written(&1, defs, scope))

  @doc """
  The type `t` in the syntax of annotations, with the given names. With
  `decorations: false`, the decorations of arrows are erased
  (`TypeSyntax.erase_decorations/1`).
  """
  def to_string(t, names \\ [], opts \\ []) do
    tree = t |> Types.factorize() |> Types.to_syntax() |> rename(names)

    tree =
      if Keyword.get(opts, :decorations, true), do: tree, else: TypeSyntax.erase_decorations(tree)

    TypeSyntax.to_string(tree)
  end

  defp rename(tree, []), do: tree

  defp rename(tree, names) do
    case whole(tree, names) do
      {:ok, name} -> name
      :error -> inside(tree, names)
    end
  end

  defp whole(tree, names) do
    with false <- leaf?(tree),
         {:ok, t} <- meaning(tree),
         {name, _} <- Enum.find(names, fn {_, n} -> Types.equal?(t, n) end) do
      {:ok, name}
    else
      _ -> :error
    end
  end

  defp inside({:rec, x, body}, names), do: {:rec, x, rename(body, names)}
  defp inside({:or, _, _} = union, names), do: union |> disjuncts() |> rename_union(names)
  defp inside({:and, a, b}, names), do: {:and, rename(a, names), rename(b, names)}
  defp inside({:not, a}, names), do: {:not, rename(a, names)}
  defp inside({:tuple, ts}, names), do: {:tuple, Enum.map(ts, &rename(&1, names))}
  defp inside({:pid, :none} = p, _names), do: p
  defp inside({:pid, t}, names), do: {:pid, rename(t, names)}

  defp inside({:arrow, args, ret, decorations}, names) do
    decorations = with {o, i} <- decorations, do: {rename(o, names), rename(i, names)}
    {:arrow, Enum.map(args, &rename(&1, names)), rename(ret, names), decorations}
  end

  defp inside(tree, _names), do: tree

  # A name replaces the disjuncts below it when their union is the name.
  defp rename_union(disjuncts, names) do
    pairs = Enum.map(disjuncts, &{&1, meaning(&1)})

    {named, rest} =
      Enum.reduce(names, {[], pairs}, fn {name, n}, {named, rest} ->
        {below, others} =
          Enum.split_with(rest, fn
            {_, {:ok, t}} -> Types.subtype?(t, n)
            _ -> false
          end)

        if length(below) >= 2 and
             Types.equal?(Types.union_all(Enum.map(below, fn {_, {:ok, t}} -> t end)), n),
           do: {[name | named], others},
           else: {named, rest}
      end)

    (Enum.reverse(named) ++ Enum.map(rest, fn {d, _} -> rename(d, names) end))
    |> Enum.reduce(&{:or, &2, &1})
  end

  defp meaning(tree), do: TypeSyntax.to_descr(tree, %{}, nil)

  defp leaf?({:atom, _}), do: true
  defp leaf?({:pid, :none}), do: true
  defp leaf?({:raw, _}), do: true
  defp leaf?({:name, _, _}), do: true
  defp leaf?({:recvar, _}), do: true
  defp leaf?({:var, _}), do: true
  defp leaf?(t) when is_atom(t), do: true
  defp leaf?(_), do: false

  defp disjuncts({:or, a, b}), do: disjuncts(a) ++ disjuncts(b)
  defp disjuncts(t), do: [t]

  defp size(t), do: t |> Types.to_syntax() |> unrec() |> disjuncts() |> length()

  defp unrec({:rec, _, body}), do: body
  defp unrec(t), do: t
end
