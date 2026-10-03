defmodule ProcessTypes.Printer do
  @moduledoc """
  Printing types with the names that `$type` defines.

  A type is read back from Descr into the syntax of annotations
  (`ProcessTypes.Types.to_syntax/1`). Then every compound subterm that denotes the same
  type as a defined name is printed as that name, and in a union a name also replaces
  the disjuncts whose union it denotes; larger names are tried first. Singleton types
  and built-in types are never renamed.
  """

  alias ProcessTypes.{TypeSyntax, Types}

  @doc """
  The names visible in `scope` (a module, or `nil` for the top level), as a list of
  `{name, type}` pairs, where `name` is the source type that prints the name: `n` for
  a name of the scope or of the top level, `M.n` for a name of another module.
  """
  def names(defs, scope) do
    defs
    |> Enum.sort_by(fn {_key, {_type, line}} -> line end)
    |> Enum.flat_map(fn {{module, n}, _} ->
      display =
        cond do
          module == scope -> {:name, nil, n}
          module == nil and not Map.has_key?(defs, {scope, n}) -> {:name, nil, n}
          module == nil -> nil
          true -> {:name, module, n}
        end

      with true <- display != nil,
           {:ok, t} <- TypeSyntax.to_descr({:name, module, n}, defs, nil),
           false <- Types.empty?(t) or Types.equal?(t, Types.term()) do
        [{display, t}]
      else
        _ -> []
      end
    end)
    # stable: names of the same size keep the order of their definitions
    |> Enum.sort_by(fn {_, t} -> -size(t) end)
  end

  @doc "The type `t` in the syntax of annotations, with the given names."
  def to_string(t, names \\ []),
    do: t |> Types.to_syntax() |> rename(names) |> TypeSyntax.to_string()

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
