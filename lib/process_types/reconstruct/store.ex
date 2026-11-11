defmodule ProcessTypes.Reconstruct.Store do
  @moduledoc """
  The bounds that a set of constraints entails on each type variable, that is, the set
  dec_⊨(X) of Definition `def:recon-dec` of the paper read per variable, and the
  operations of Appendix D that only look at these bounds: chains between variables,
  polarities (Definition `def:recon-polarity`) and the closure that defines the
  unknowns and the dependencies (Definitions `def:recon-unknowns` and
  `def:recon-depends`).

  A store is `%{upper: %{ζ => [u]}, lower: %{ζ => [l]}, links: %{ζ => [η]}, pairs: [{s, u}]}`:
  the entailed bounds ζ ≤ u and l ≤ ζ; the pairs ζ ≤ η between variables found in any
  alternative of a normal form (the set dec(X), for Definition `def:recon-selfsend`);
  and every constraint s ≤ u, original or entailed.

  Polarities are tested semantically: ζ occurs only positively in u when u is monotone
  in ζ, only negatively when it is antitone, and does not matter when it is both.
  """

  alias ProcessTypes.Reconstruct.Bounds
  alias ProcessTypes.Types

  @doc """
  The store of a list of constraints, each `{s, t}` or a map with `:sub`, `:sup` and
  `:kind`; `extra` are bounds entailed otherwise.

  The constraint of an application compares pointed domains (`Types.pointed/1`): the
  bound that it gives to a variable at the top of the argument contains the point ℧,
  which belongs to no type of the language, and is removed.
  """
  def new(constraints, extra \\ []) do
    read =
      Enum.map(constraints, fn
        {s, t} ->
          bounds(s, t)

        %{sub: s, sup: t, kind: {:app, _, _, argument, _, _, _}} ->
          unpoint(bounds(s, t), Types.top_vars(argument))

        %{sub: s, sup: t} ->
          bounds(s, t)
      end)

    constraints =
      Enum.map(constraints, fn
        {s, t} -> {s, t}
        %{sub: s, sup: t} -> {s, t}
      end)
    entailed = Enum.flat_map(read, & &1.entailed) ++ extra
    all = Enum.flat_map(read, & &1.all) ++ extra

    %{
      upper: group(entailed, :upper),
      lower: group(entailed, :lower),
      links: links(all),
      pairs:
        constraints ++
          Enum.map(entailed, fn
            {:upper, v, u} -> {v, u}
            {:lower, v, l} -> {l, v}
          end)
    }
  end

  defp unpoint(read, variables) do
    if MapSet.size(variables) == 0 do
      read
    else
      strip = fn
        {:upper, v, u} = bound ->
          if MapSet.member?(variables, v), do: {:upper, v, Types.unpointed(u)}, else: bound

        bound ->
          bound
      end

      %{entailed: Enum.map(read.entailed, strip), all: Enum.map(read.all, strip)}
    end
  end

  # Bounds.of/2, memoized for the time of a reconstruction (see with_cache/1).
  defp bounds(s, t) do
    key = {:recon_bounds, s, t}

    case Process.get(key) do
      nil ->
        result = Bounds.of(s, t)
        Process.put(key, result)
        result

      result ->
        result
    end
  end

  @doc "Runs `fun` and then forgets what the stores and the polarities memoized."
  def with_cache(fun) do
    fun.()
  after
    for {{tag, _, _} = key, _} <- Process.get(), tag in [:recon_bounds, :recon_polarity],
        do: Process.delete(key)
  end

  defp group(bounds, kind) do
    for {^kind, v, t} <- bounds, reduce: %{} do
      acc -> Map.update(acc, v, [t], &if(t in &1, do: &1, else: [t | &1]))
    end
  end

  defp links(bounds) do
    for bound <- bounds, {a, b} <- link(bound), reduce: %{} do
      acc -> Map.update(acc, a, [b], &if(b in &1, do: &1, else: [b | &1]))
    end
  end

  defp link({:upper, v, u}), do: if(w = variable(u), do: [{v, w}], else: [])
  defp link({:lower, v, l}), do: if(w = variable(l), do: [{w, v}], else: [])

  @doc "The variable that `t` is, or `nil`."
  def variable(t) do
    case MapSet.to_list(Types.syntactic_vars(t)) do
      [v] -> if Types.equal?(t, v), do: v
      _ -> nil
    end
  end

  def uppers(store, v), do: Map.get(store.upper, v, [])
  def lowers(store, v), do: Map.get(store.lower, v, [])

  @doc "The variables above `v` by entailed bounds between variables, `v` included."
  def above(store, v), do: reach([v], MapSet.new(), &entailed_above(store, &1))

  @doc "The variables below `v` by the links of dec(X), `v` included."
  def linked_below(store, v) do
    below =
      for {a, bs} <- store.links, b <- bs, reduce: %{} do
        acc -> Map.update(acc, b, [a], &[a | &1])
      end

    reach([v], MapSet.new(), &Map.get(below, &1, []))
  end

  @doc "The variables that the constraints force to `term()`."
  def forced_top(store) do
    roots = for {v, ls} <- store.lower, Enum.any?(ls, &Types.subtype?(Types.term(), &1)), do: v
    reach(roots, MapSet.new(), &entailed_above(store, &1))
  end

  defp entailed_above(store, v) do
    ups = for u <- uppers(store, v), w = variable(u), do: w
    lows = for {w, ls} <- store.lower, Enum.any?(ls, &(variable(&1) == v)), do: w
    ups ++ lows
  end

  defp reach([], seen, _next), do: seen

  defp reach([v | rest], seen, next) do
    if MapSet.member?(seen, v),
      do: reach(rest, seen, next),
      else: reach(next.(v) ++ rest, MapSet.put(seen, v), next)
  end

  @doc """
  The polarities with which the variables of `t` occur in it: a list of `{ζ, :pos}` and
  `{ζ, :neg}`.
  """
  def polarities(t) do
    key = {:recon_polarity, t, nil}

    case Process.get(key) do
      nil ->
        result =
          Enum.flat_map(Types.syntactic_vars(t), fn v ->
            case {Types.monotone?(t, v), Types.antitone?(t, v)} do
              {true, true} -> []
              {true, false} -> [{v, :pos}]
              {false, true} -> [{v, :neg}]
              {false, false} -> [{v, :pos}, {v, :neg}]
            end
          end)

        Process.put(key, result)
        result

      result ->
        result
    end
  end

  @doc """
  The least set of pairs `{ζ, polarity}` that contains `seeds` and is closed under the
  bounds of the store: for `{ζ, :pos}`, the variables of the upper bounds of ζ with
  their polarity; for `{ζ, :neg}`, those of its lower bounds with the opposite one.
  The variables of `exclude` are left out. Returns a map from variables to the list of
  their polarities.
  """
  def closure(store, seeds, exclude) do
    seeds = Enum.reject(seeds, fn {v, _} -> MapSet.member?(exclude, v) end)
    close(seeds, MapSet.new(), store, exclude)
  end

  defp close([], seen, _store, _exclude) do
    Enum.group_by(seen, &elem(&1, 0), &elem(&1, 1))
  end

  defp close([{v, p} = pair | rest], seen, store, exclude) do
    if MapSet.member?(seen, pair) do
      close(rest, seen, store, exclude)
    else
      more =
        case p do
          :pos -> for u <- uppers(store, v), pair <- polarities(u), do: pair
          :neg -> for l <- lowers(store, v), {w, q} <- polarities(l), do: {w, flip(q)}
        end

      more = Enum.reject(more, fn {w, _} -> MapSet.member?(exclude, w) end)
      close(more ++ rest, MapSet.put(seen, pair), store, exclude)
    end
  end

  defp flip(:pos), do: :neg
  defp flip(:neg), do: :pos
end
