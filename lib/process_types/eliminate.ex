defmodule ProcessTypes.Eliminate do
  @moduledoc """
  Eliminates, before tallying, the variables that only their bare bounds make
  constrained in both directions (`_claude/INFERENCE-SCALING.md` of the paper, D1).

  A variable γ is eliminated by its bare upper bounds when every constraint that
  mentions γ is either γ ≤ u with γ not in u, or s ≤ t with s ∧ ¬t antitone in γ: then
  the constraints are satisfiable iff those obtained by dropping the bare bounds and
  replacing γ by the intersection u of their right-hand sides are, and γ ↦ uσ extends a
  solution σ of the latter to the former. Dually, β is eliminated by its bare lower bounds
  l ≤ β, replaced by their union, when every other constraint is monotone in β. This is
  the step that Section 8.3 of the paper takes for `halve`, where the components of a
  tuple pattern are taken equal to their upper bounds.

  Antitonicity in γ is tested semantically, as (s ∧ ¬t){γ ∨ δ/γ} ≤ s ∧ ¬t for a fresh δ,
  and monotonicity with γ ∧ δ. `subtype?/2` only errs by answering false (a known limit
  of Descr), which only prevents an elimination.
  """

  alias ProcessTypes.Types

  @type constraint :: {Types.t(), Types.t()}
  @type elimination :: {Types.t(), Types.t()}

  @doc """
  Eliminates variables from `constraints`, except those of `keep`, until none
  qualifies. Returns the remaining constraints and the eliminations `{variable,
  bound}`, the last one first. Eliminating a variable preserves satisfiability, not the
  most precise solution of that variable: the variables of the types to report are
  kept.
  """
  @spec eliminate([constraint], MapSet.t()) :: {[constraint], [elimination]}
  def eliminate(constraints, keep \\ MapSet.new()), do: pass(constraints, keep, [])

  @doc """
  Extends a solution of the remaining constraints to the eliminated variables. A bound
  may mention variables eliminated after its own, which are therefore extended first.
  """
  @spec reconstruct(map(), [elimination]) :: map()
  def reconstruct(sigma, eliminations) do
    Enum.reduce(eliminations, sigma, fn {v, bound}, sigma ->
      Map.put(sigma, v, Types.substitute(bound, sigma))
    end)
  end

  # One pass tries every variable once, against the constraints as they are when it is
  # tried; passes are repeated while one of them eliminates something.
  defp pass(constraints, keep, eliminations) do
    {constraints, more} =
      constraints
      |> variables()
      |> Enum.reject(&MapSet.member?(keep, &1))
      |> Enum.reduce({constraints, []}, fn v, {constraints, more} ->
        case elimination(constraints, v) do
          {:ok, bound, bare} ->
            {constraints |> Enum.reject(&(&1 in bare)) |> Enum.map(&substitute(&1, v, bound)),
             [{v, bound} | more]}

          :error ->
            {constraints, more}
        end
      end)

    if more == [],
      do: {constraints, eliminations},
      else: pass(constraints, keep, more ++ eliminations)
  end

  defp elimination(constraints, v) do
    occurrences = Enum.filter(constraints, &MapSet.member?(vars(&1), v))
    {uppers, others} = Enum.split_with(occurrences, &upper_bound?(&1, v))
    {lowers, others_l} = Enum.split_with(occurrences, &lower_bound?(&1, v))

    cond do
      occurrences == [] ->
        :error

      Enum.all?(others, &antitone?(&1, v)) ->
        {:ok, Types.intersection_all(Enum.map(uppers, &elem(&1, 1))), uppers}

      Enum.all?(others_l, &monotone?(&1, v)) ->
        {:ok, Types.union_all(Enum.map(lowers, &elem(&1, 0))), lowers}

      true ->
        :error
    end
  end

  defp upper_bound?({s, t}, v), do: Types.equal?(s, v) and not mentions?(t, v)
  defp lower_bound?({s, t}, v), do: Types.equal?(t, v) and not mentions?(s, v)

  defp antitone?({s, t}, v) do
    d = Types.difference(s, t)
    Types.subtype?(Types.substitute(d, %{v => Types.union(v, Types.var(:delta))}), d)
  end

  defp monotone?({s, t}, v) do
    d = Types.difference(s, t)
    Types.subtype?(Types.substitute(d, %{v => Types.intersection(v, Types.var(:delta))}), d)
  end

  defp substitute({s, t}, v, bound),
    do: {Types.substitute(s, %{v => bound}), Types.substitute(t, %{v => bound})}

  defp mentions?(t, v), do: MapSet.member?(Types.syntactic_vars(t), v)
  defp vars({s, t}), do: MapSet.union(Types.syntactic_vars(s), Types.syntactic_vars(t))

  defp variables(constraints),
    do: constraints |> Enum.flat_map(&MapSet.to_list(vars(&1))) |> Enum.uniq()
end
