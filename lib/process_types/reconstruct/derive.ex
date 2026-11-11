defmodule ProcessTypes.Reconstruct.Derive do
  @moduledoc """
  The derivation step of the reconstruction (Section 9.2 of the paper): for an
  unannotated `spawn` of bracket [β, α], the `receive`s that its process runs
  (Definition `def:recon-runs`), their coverage, the self-sends of β (Definition
  `def:recon-selfsend`) and the types m_j of the demands (Definition
  `def:recon-demand`).

  The `receive`s run at α are those whose input decoration δ is above α by the bounds
  between variables that the constraints entail, or is forced to `term()`, or is a
  ground type above the ground upper bounds that these chains reach: a sufficient
  condition for C ⊨ α ≤ δ. The ground upper bounds reached, which come from written
  decorations, are returned as `ub`: they bound the interface too.
  """

  alias ProcessTypes.Checker
  alias ProcessTypes.Reconstruct.Store
  alias ProcessTypes.Types

  @doc """
  `world` holds the constraints of the program as `%{sub, sup, kind}` (`constraints`),
  their store (`store`), the uses of rule i-receive (`receives`) and the roles of the
  variables (`roles`); `spawn` is `%{o: β, i: α, …}`. Returns the receives run, the
  coverage, `ub`, and the identifiers of the constraints that are self-sends of β.
  """
  def derive(world, spawn) do
    store = world.store
    reach = Store.above(store, spawn.i)

    ub =
      for v <- reach, u <- Store.uppers(store, v), Types.ground?(u), reduce: Types.term() do
        acc -> Types.intersection(acc, u)
      end

    forced = world.forced

    rcv =
      Enum.filter(world.receives, fn r ->
        case Store.variable(r.delta) do
          nil -> Types.ground?(r.delta) and Types.subtype?(ub, r.delta)
          d -> MapSet.member?(reach, d) or MapSet.member?(forced, d)
        end
      end)

    cov =
      for r <- rcv, b <- r.branches, reduce: Types.none() do
        acc -> Types.union(acc, Checker.accepted(b.pattern))
      end

    linked =
      store
      |> Store.linked_below(spawn.o)
      |> Enum.filter(&(world.roles[&1] == :o or &1 == spawn.o))

    self_sends =
      for %{kind: {:send, p, _m}, id: id} <- world.constraints,
          Enum.any?(linked, &Types.subtype?(Types.pid(&1), p)),
          into: MapSet.new(),
          do: id

    %{rcv: rcv, cov: cov, ub: ub, self_sends: self_sends, captures: captures(rcv)}
  end

  @doc "The types Γ_j(x) of the capture variables of the branches of `receives`, when variables."
  def captures(receives) do
    for r <- receives, b <- r.branches, {_x, t} <- b.env, v = Store.variable(t), into: MapSet.new(),
      do: v
  end

  @doc """
  The type m_j of a branch for the store of a constraint set X: its pattern with each
  capture variable replaced by the meet of the upper bounds of its type in dec_⊨(X).
  A capture variable whose type is no type variable (the branch was typed at a ground
  input decoration, whose constraints are checked at once) is replaced by `term()`.
  """
  def demand_type(branch, store), do: fill(branch.pattern, branch.env, store)

  defp fill({:pvar, _, x}, env, store) do
    case Store.variable(Map.get(env, x, Types.term())) do
      nil -> Types.term()
      v -> meet(Store.uppers(store, v))
    end
  end

  defp fill({:ptuple, _, ps}, env, store), do: Types.tuple(Enum.map(ps, &fill(&1, env, store)))

  defp fill({:pand, _, p1, p2}, env, store),
    do: Types.intersection(fill(p1, env, store), fill(p2, env, store))

  defp fill(p, _env, _store), do: Checker.accepted(p)
  # The meet of several bounds; when they are pid types, pid(s₁) ∧ pid(s₂) is written
  # pid(s₁ ∨ s₂), which is equivalent and prints as one type.
  defp meet([u]), do: u

  defp meet(uppers) do
    u = Types.intersection_all(uppers)

    with [_ | _] <- uppers,
         true <- Enum.all?(uppers, &Types.subtype?(&1, Types.pid())),
         p = Types.pid(Types.union_all(Enum.map(uppers, &Types.interface/1))),
         true <- Types.equal?(p, u) do
      p
    else
      _ -> u
    end
  end
end
