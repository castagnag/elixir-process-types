defmodule ProcessTypes.Reconstruct.Bounds do
  @moduledoc """
  The bounds on type variables that a constraint entails: the decompositions
  dec_⊨ and dec of Definition `def:recon-dec` of the paper (Appendix D), computed
  from the normal form that tallying gives to the constraint (`Types.normalize/3`)
  instead of by cases on its form. They are therefore taken up to equivalence: a
  refinement (ζ ∧ g) ∖ g' ≤ t is read as the bound ζ ≤ t ∨ ¬g ∨ g'.

  A bound is `{:upper, ζ, u}`, for ζ ≤ u, or `{:lower, ζ, l}`, for l ≤ ζ.

  The normal form of s ≤ t is a list of alternatives, each a list of bounds
  l ≤ ζ ≤ u, of which the constraint is the disjunction.

  - An alternative that implies another one is dropped (the constraint of an
    application yields the alternative "the input decoration of the callee is
    `term()`", which implies the bound of the other one).
  - With one alternative left, its bounds are entailed. Normalization isolates one
    variable per summand, the smallest: for l ≤ ζ ≤ u with both bounds proper, the
    constraint l ≤ u that they induce is decomposed too (one step of the saturation
    of tallying; this is clause 1 of the definition, for a union on the left). When
    s ∖ t is monotone in ζ, the lower bound is an artifact of the normal form (l is
    then empty under every solution): it is replaced by the decomposition of l ≤ 𝟘;
    dually when it is antitone. A bound between ζ and a type with variables at its
    top is read for these variables too, by normalizing it again with ζ fixed.
  - With several alternatives, a variable bounded from above in each of them has the
    union of these bounds as entailed upper bound, and dually. This is how a tuple
    constraint splits at a component when the other components are inhabited
    (clause 4): the alternative "this component is empty" keeps the bound of that
    component and makes those of the others trivial.

  `dec` keeps the bounds of every alternative: it is used only for the links between
  output decorations (Definition `def:recon-selfsend`).
  """

  alias ProcessTypes.Types

  @type bound :: {:upper | :lower, Types.t(), Types.t()}

  @max_depth 8

  @doc "The bounds of `s ≤ t`: `%{entailed: [bound], all: [bound]}`."
  @spec of(Types.t(), Types.t()) :: %{entailed: [bound], all: [bound]}
  def of(s, t) do
    {entailed, all} = go(s, t, MapSet.new(), @max_depth)
    %{entailed: Enum.uniq(entailed), all: Enum.uniq(all)}
  end

  defp go(_s, _t, _fixed, 0), do: {[], []}

  defp go(s, t, fixed, depth) do
    case s |> Types.normalize(t, fixed) |> prune() do
      [] ->
        {[], []}

      [alternative] ->
        d = Types.difference(s, t)

        Enum.reduce(alternative, {[], []}, fn triple, {entailed, all} ->
          {e, a} = triple(triple, d, fixed, depth)
          {e ++ entailed, a ++ all}
        end)

      alternatives ->
        read = Enum.map(alternatives, fn alt -> Enum.flat_map(alt, &simple/1) end)
        {join(read), Enum.concat(read)}
    end
  end

  defp simple({l, v, u}) do
    if(proper_upper?(u), do: [{:upper, v, u}], else: []) ++
      if proper_lower?(l), do: [{:lower, v, l}], else: []
  end

  defp proper_upper?(u), do: not Types.subtype?(Types.term(), u)
  defp proper_lower?(l), do: not Types.empty?(l)

  # The entailed bounds of one alternative l ≤ v ≤ u of the constraint of difference d.
  defp triple({l, v, u}, d, fixed, depth) do
    case {proper_lower?(l), proper_upper?(u)} do
      {false, false} ->
        {[], []}

      {false, true} ->
        upper(v, u, fixed, depth)

      {true, false} ->
        lower(v, l, fixed, depth)

      {true, true} ->
        cond do
          Types.monotone?(d, v) ->
            merge(upper(v, u, fixed, depth), go(l, Types.none(), fixed, depth - 1))

          Types.antitone?(d, v) ->
            merge(lower(v, l, fixed, depth), go(Types.term(), u, fixed, depth - 1))

          true ->
            upper(v, u, fixed, depth)
            |> merge(lower(v, l, fixed, depth))
            |> merge(go(l, u, fixed, depth - 1))
        end
    end
  end

  # v ≤ u, read also as a bound of the variables at the top of u.
  defp upper(v, u, fixed, depth) do
    here = {[{:upper, v, u}], [{:upper, v, u}]}

    if flip?(u, v, fixed),
      do: merge(here, go(v, u, MapSet.put(fixed, v), depth - 1)),
      else: here
  end

  defp lower(v, l, fixed, depth) do
    here = {[{:lower, v, l}], [{:lower, v, l}]}

    if flip?(l, v, fixed),
      do: merge(here, go(l, v, MapSet.put(fixed, v), depth - 1)),
      else: here
  end

  defp flip?(t, v, fixed),
    do: not MapSet.subset?(Types.top_vars(t), MapSet.put(fixed, v))

  defp merge({e1, a1}, {e2, a2}), do: {e1 ++ e2, a1 ++ a2}

  # The bounds that hold in every alternative.
  defp join([first | rest] = read) do
    for {kind, v, _} <- first,
        Enum.all?(rest, fn bounds -> Enum.any?(bounds, &match?({^kind, ^v, _}, &1)) end),
        uniq: true do
      types = for bounds <- read, {^kind, ^v, t} <- bounds, do: t

      case kind do
        :upper -> {:upper, v, Types.union_all(types)}
        :lower -> {:lower, v, Types.intersection_all(types)}
      end
    end
    |> Enum.filter(fn
      {:upper, _, u} -> proper_upper?(u)
      {:lower, _, l} -> proper_lower?(l)
    end)
  end

  # Drops the alternatives that imply another one.
  defp prune([_] = alternatives), do: alternatives
  defp prune([]), do: []

  defp prune(alternatives) do
    indexed = Enum.with_index(alternatives)

    for {a, i} <- indexed,
        not Enum.any?(indexed, fn {b, j} ->
          i != j and implies?(a, b) and not (j > i and implies?(b, a))
        end),
        do: a
  end

  # A sufficient condition: under the variables that a pins (lower ≃ upper), the bounds
  # that a gives to each variable are within those of b.
  defp implies?(a, b) do
    pinned =
      for {l, v, u} <- a, Types.subtype?(u, l), into: %{}, do: {v, l}

    Enum.all?(b, fn {l2, v, u2} ->
      {l1, u1} =
        case Enum.find(a, &match?({_, ^v, _}, &1)) do
          {l1, _, u1} -> {l1, u1}
          nil -> {Types.none(), Types.term()}
        end

      Types.subtype?(Types.substitute(l2, pinned), l1) and
        Types.subtype?(u1, Types.substitute(u2, pinned))
    end)
  end
end
