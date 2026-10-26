defmodule ProcessTypes.EliminateTest do
  use ExUnit.Case, async: true

  import ProcessTypes.Types
  alias ProcessTypes.Eliminate

  # The requirement of halve (Section 8.3): the receive matches α ∧ {:half, term()}
  # against {γ₁, γ₂}, the test pattern :half bounds γ₁, and div(x, 2) bounds γ₂.
  defp halve(alpha, g1, g2) do
    half = atom([:half])

    [
      {intersection(alpha, tuple([half, term()])), tuple([g1, g2])},
      {g1, half},
      {g2, integer()}
    ]
  end

  test "the projections of halve are taken equal to their upper bounds" do
    {alpha, g1, g2} = {var(:alpha), var(:g1), var(:g2)}
    {[{s, t}], eliminations} = Eliminate.eliminate(halve(alpha, g1, g2), MapSet.new([alpha]))

    assert equal?(s, intersection(alpha, tuple([atom([:half]), term()])))
    assert equal?(t, tuple([atom([:half]), integer()]))

    sigma = Eliminate.reconstruct(%{}, eliminations)
    assert equal?(sigma[g1], atom([:half]))
    assert equal?(sigma[g2], integer())
  end

  test "a variable bounded from both sides, not only by bare bounds, is kept" do
    g = var(:g)
    constraints = [{tuple([g]), tuple([integer()])}, {tuple([atom([:a])]), tuple([g])}]
    assert Eliminate.eliminate(constraints) == {constraints, []}
  end

  test "elimination preserves satisfiability, and the extended solution solves the original" do
    g = var(:g)
    unsat = [{tuple([atom([:a])]), tuple([g])}, {g, integer()}]
    {reduced, _} = Eliminate.eliminate(unsat)
    assert tally(unsat) == [] and tally(reduced) == []

    {alpha, g1, g2} = {var(:alpha), var(:g1), var(:g2)}
    constraints = [{tuple([atom([:half]), integer()]), alpha} | halve(alpha, g1, g2)]
    {reduced, eliminations} = Eliminate.eliminate(constraints)
    assert [sigma] = tally_first(reduced)
    sigma = Eliminate.reconstruct(sigma, eliminations)

    assert Enum.all?(constraints, fn {s, t} ->
             subtype?(substitute(s, sigma), substitute(t, sigma))
           end)
  end
end
