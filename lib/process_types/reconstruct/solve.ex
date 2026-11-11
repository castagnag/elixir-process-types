defmodule ProcessTypes.Reconstruct.Solve do
  @moduledoc """
  The solving step of the reconstruction (Section 9.3 and Appendix D of the paper).

  - `mailbox_pure/2`: the mailbox-pure functions (Definition `def:recon-pure`) among the
    named functions, and the substitution θ_M of their decorations.
  - `dependencies/3`: the `spawn`s on which a `spawn` depends (Definition
    `def:recon-depends`).
  - `interface/4`: the reduced constraint set (Definition `def:recon-cstar`), the
    unknowns and the polarity hypothesis (Definitions `def:recon-unknowns` and
    `def:recon-hyp`), the extrema (Definition `def:recon-elim`) and the solution of
    x = F(x, x) (Definition `def:recon-interface`).

  The extrema and x are the solution of one system of equations. A bound may have
  unknowns at its top (a chain ζ ≤ η): as in the proof of Lemma `lem:recon-elim`, such
  an occurrence is replaced by the bound of that unknown, and by `term()` (for a
  covariant unknown) or `none()` (for a contravariant one) when the chain comes back to
  an unknown it started from, which gives the greatest and the least solution; the
  system left is guarded and has one solution (`Types.solve_equations/1`).
  """

  alias ProcessTypes.Reconstruct.{Derive, Store}
  alias ProcessTypes.Types

  @max_arrows 8

  # Mailbox-pure functions

  @doc """
  Returns `{pure, theta}`: the keys of the mailbox-pure named functions with their
  arrows, and the substitution that maps their input decorations to `term()` and their
  output decorations to `none()`.
  """
  def mailbox_pure(program, sigs) do
    candidates =
      for {key, fun} <- program.funs,
          %{arrows: arrows} = Map.fetch!(sigs, key),
          is_list(arrows),
          Enum.all?(arrows, &(Types.ground?(&1.s) and Types.ground?(&1.t))),
          not mentions?(fun.clauses, [:receive, :self, :apply]),
          into: %{},
          do: {key, {arrows, calls(fun.clauses, fun.module)}}

    pure = grow(candidates, MapSet.new())

    theta =
      for key <- pure, {arrows, _} = Map.fetch!(candidates, key), a <- arrows, reduce: %{} do
        theta ->
          theta
          |> put_variable(a.i, Types.term())
          |> put_variable(a.o, Types.none())
      end

    {Map.new(pure, &{&1, elem(Map.fetch!(candidates, &1), 0)}), theta}
  end

  # The least set: a candidate enters when all the functions it calls are in.
  defp grow(candidates, pure) do
    more =
      for {key, {_arrows, calls}} <- candidates,
          not MapSet.member?(pure, key),
          Enum.all?(calls, &MapSet.member?(pure, &1)),
          do: key

    if more == [], do: pure, else: grow(candidates, MapSet.union(pure, MapSet.new(more)))
  end

  defp put_variable(theta, t, image) do
    case Store.variable(t) do
      nil -> theta
      v -> Map.put(theta, v, image)
    end
  end

  defp mentions?(term, tags) do
    case term do
      t when is_tuple(t) ->
        (tuple_size(t) > 0 and elem(t, 0) in tags) or mentions?(Tuple.to_list(t), tags)

      [h | rest] ->
        mentions?(h, tags) or mentions?(rest, tags)

      _ ->
        false
    end
  end

  defp calls(term, module) do
    case term do
      {:call, _, {:local, f}, args} -> [{module, f, length(args)} | calls(args, module)]
      {:call, _, {:remote, m, f}, args} -> [{m, f, length(args)} | calls(args, module)]
      t when is_tuple(t) -> calls(Tuple.to_list(t), module)
      [h | rest] -> calls(h, module) ++ calls(rest, module)
      _ -> []
    end
  end

  # Overloaded mailbox-pure callees

  # The constraints of the applications of an overloaded mailbox-pure function to an
  # argument in which the type of a capture variable occurs.
  defp overloaded(constraints, pure, captures) do
    Enum.filter(constraints, fn
      %{kind: {:app, head, _f, s, _o, _i, _g}} when head != nil ->
        case pure do
          %{^head => arrows} when length(arrows) in 2..@max_arrows//1 ->
            not MapSet.disjoint?(Types.syntactic_vars(s), captures)

          _ ->
            false
        end

      _ ->
        false
    end)
  end

  @doc "The inverse image f⁻¹(g) of Definition `def:recon-inverse`, for the arrows of f."
  def inverse_image(arrows, g) do
    for subset <- subsets(arrows),
        subset != [],
        rest = arrows -- subset,
        rest == [] or
          not Types.subtype?(Types.intersection_all(Enum.map(rest, & &1.t)), g),
        reduce: Types.term() do
      acc -> Types.intersection(acc, Types.union_all(Enum.map(subset, & &1.s)))
    end
  end

  defp subsets([]), do: [[]]

  defp subsets([x | rest]) do
    tails = subsets(rest)
    Enum.map(tails, &[x | &1]) ++ tails
  end

  # Dependencies

  @doc """
  The occurrences of the unannotated `spawn`s on which `spawn` depends: those of which
  a variable is in the set Q of Definition `def:recon-depends`.
  """
  def dependencies(world, spawn, derived) do
    constraints = without(world.constraints, derived.self_sends)
    store = Store.new(constraints, world.selection)

    results =
      for %{kind: {:app, _, _, _, _, _, g}} <- overloaded(constraints, world.pure, derived.captures),
          v = Store.variable(g),
          do: v

    sources = MapSet.union(derived.captures, MapSet.new(results))

    seeds =
      for {s, u} <- store.pairs,
          not MapSet.disjoint?(Types.syntactic_vars(s), sources),
          pair <- Store.polarities(u),
          do: pair

    q = Store.closure(store, seeds, MapSet.new([spawn.i, spawn.o]))

    for other <- world.spawns,
        other.occurrence != spawn.occurrence,
        Enum.any?([other.i, other.o, other.pid], &is_map_key(q, &1)),
        do: other.occurrence
  end

  # The interface

  @doc """
  The interface of `spawn`: `{:ok, t}`, or `{:error, reason}` with reason `:polarity`
  (the polarity hypothesis fails; the variable is given) or `:unguarded` (the equation
  x = F(x, x) does not determine x). `solved` are the spawns on which it depends, as
  `{spawn, interface}`.
  """
  def interface(world, spawn, derived, solved) do
    theta = Map.new(solved, fn {other, t} -> {other.pid, t} end)

    brackets =
      Enum.flat_map(solved, fn {other, t} -> [{other.o, t}, {t, other.i}] end)

    constraints =
      world.constraints
      |> without(derived.self_sends)
      |> Enum.map(&substitute(&1, theta))

    # C_1, where the upper bounds of the results of the overloaded calls are read.
    store1 = Store.new(constraints ++ brackets, world.selection)

    replaced =
      constraints
      |> overloaded(world.pure, derived.captures)
      |> Enum.filter(fn %{kind: {:app, _, _, _, _, _, g}} ->
        v = Store.variable(g)
        v != nil and Enum.all?(Store.uppers(store1, v), &Types.ground?/1)
      end)

    bounds =
      Enum.map(replaced, fn %{kind: {:app, head, _f, s, _o, _i, g}} ->
        g_hat = Types.intersection_all(Store.uppers(store1, Store.variable(g)))
        {s, inverse_image(Map.fetch!(world.pure, head), g_hat)}
      end)

    # C*
    kept = without(constraints, MapSet.new(replaced, & &1.id))
    store = Store.new(kept ++ bounds ++ brackets, world.selection)

    # cov ∧ ⋀_j (m_j ∨ ¬q_j), written per receive as (⋁_j q_j ∧ m_j) ∨ ¬(⋁_j q_j): the
    # same type, since the q_j of a receive are disjoint, in a form that prints as the
    # union of the demand types. A single receive needs no complement.
    demands =
      for r <- derived.rcv do
        served =
          Types.union_all(
            for b <- r.branches do
              m = Derive.demand_type(b, store)

              if Types.subtype?(ProcessTypes.Checker.accepted(b.pattern), b.q),
                do: m,
                else: Types.intersection(m, b.q)
            end
          )

        selected = Types.union_all(Enum.map(r.branches, & &1.q))
        {served, selected}
      end

    f =
      case demands do
        [{served, _selected}] ->
          Types.intersection(served, derived.ub)

        _ ->
          Types.intersection_all([
            derived.cov,
            derived.ub
            | Enum.map(demands, fn {served, selected} ->
                Types.union(served, Types.negation(selected))
              end)
          ])
      end
    exclude = MapSet.new([spawn.i, spawn.o])
    unknowns = Store.closure(store, Store.polarities(f), exclude)

    case Enum.find(unknowns, fn {_v, ps} -> length(ps) > 1 end) do
      {v, _} -> {:error, {:polarity, v}}
      nil -> solve(f, Map.new(unknowns, fn {v, [p]} -> {v, p} end), store, spawn)
    end
  end

  defp without(constraints, ids), do: Enum.reject(constraints, &MapSet.member?(ids, &1.id))

  defp substitute(c, theta) when theta == %{}, do: c

  defp substitute(c, theta) do
    kind =
      case c.kind do
        {:app, head, f, s, o, i, g} -> {:app, head, sub(f, theta), sub(s, theta), o, i, g}
        {:send, p, m} -> {:send, sub(p, theta), sub(m, theta)}
        kind -> kind
      end

    %{c | sub: sub(c.sub, theta), sup: sub(c.sup, theta), kind: kind}
  end

  defp sub(t, theta), do: Types.substitute(t, theta)

  # The system: x = F(x, x) and ζ = its extremal bound, with α and β replaced by x.
  defp solve(f, unknowns, store, spawn) do
    x = Types.var(:interface)
    to_x = %{spawn.i => x, spawn.o => x}
    polarity = Map.put(unknowns, x, :pos)

    raw = fn
      ^x ->
        Types.substitute(f, to_x)

      v ->
        case Map.fetch!(polarity, v) do
          :pos -> Types.substitute(Types.intersection_all(Store.uppers(store, v)), to_x)
          :neg -> Types.substitute(Types.union_all(Store.lowers(store, v)), to_x)
        end
    end

    try do
      body = fn v -> cut(v, [], raw, polarity, x) end
      equations = collect([x], %{}, body, polarity)
      others = equations |> Map.keys() |> List.delete(x) |> Enum.with_index(1)

      names =
        Map.new([{x, :t} | Enum.map(others, fn {v, k} -> {v, String.to_atom("t#{k}")} end)])

      solution = Types.solve_equations(equations, names)
      t = Map.fetch!(solution, x)
      if Types.ground?(t), do: {:ok, Types.factorize(t)}, else: {:error, :unguarded}
    catch
      :unguarded -> {:error, :unguarded}
    end
  end

  # The bound of v with the unknowns at its top replaced by their own bounds. A chain
  # that comes back to an unknown of the stack is cut at the neutral element of that
  # unknown; it must not come back to x, which the equation would then not determine.
  defp cut(v, stack, raw, polarity, x) do
    t = raw.(v)
    stack = [v | stack]

    tops = for w <- Types.top_vars(t), is_map_key(polarity, w), do: w

    if tops == [] do
      t
    else
      Types.substitute_top(
        t,
        Map.new(tops, fn w ->
          cond do
            w in stack and w == x -> throw(:unguarded)
            w in stack -> {w, neutral(Map.fetch!(polarity, w))}
            true -> {w, cut(w, stack, raw, polarity, x)}
          end
        end)
      )
    end
  end

  defp neutral(:pos), do: Types.term()
  defp neutral(:neg), do: Types.none()

  # The equations of x and of the unknowns that occur, below constructors, in them.
  defp collect([], equations, _body, _polarity), do: equations

  defp collect([v | rest], equations, body, polarity) do
    if is_map_key(equations, v) do
      collect(rest, equations, body, polarity)
    else
      t = body.(v)
      more = for w <- Types.syntactic_vars(t), is_map_key(polarity, w), do: w
      collect(more ++ rest, Map.put(equations, v, t), body, polarity)
    end
  end
end
