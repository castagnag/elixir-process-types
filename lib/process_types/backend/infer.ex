defmodule ProcessTypes.Backend.Infer do
  @moduledoc """
  Inference (Section 8 of the paper; GRAMMAR.md, §9).

  Annotations are decorated with type variables (decorate(·), as
  `ProcessTypes.TypeGraph.decorate/4` computes it), once per occurrence. The rules mint
  fresh variables: α, β, γ of i-app, γ_k of pe-tuple, the brackets of i-abs (for an
  unannotated `fn`) and of i-spawn (for a spawned body and for the main process). A
  constraint without variables is checked at once, as in ground mode; the others are
  recorded in the order in which the rules generate them, and `finish/1` solves them
  together by tallying.

  `finish/1` splits the recorded constraints into components that share no variable,
  and tallies each. When a component has no solution, its errors are the constraints
  that make it unsatisfiable in generation order: a binary search finds the shortest
  prefix without solution, its last constraint is reported and dropped, and the search
  resumes after it.

  Types are reported as instances of a solution σ, followed by ρ₀, which maps the
  variables left to ground types according to their role: output decorations, results
  and projections to `none()`, input decorations to `term()`. Every ground instance of
  a solution is a valid typing (Corollary `cor:inferred-safety`); this one gives the
  most precise arrows, an input decoration bounded from above being printed as its
  bound, which is the requirement of Section 8.3.

  Rule i-app emits the single constraint f ≤ s →_o^i γ, at the bracket [o, i] of the
  application. Option `app: :literal` emits instead β ≤ o, i ≤ α and f ≤ s →_β^α γ for
  fresh α and β, the form of the rule in earlier versions of the paper, which is
  equivalent (eliminating α and β gives the single constraint back); the default is
  `:compact`.

  Every tallying call first eliminates the variables that only their bare bounds
  constrain (`ProcessTypes.Eliminate`, which preserves satisfiability), then searches
  for one solution of what remains (`Types.tally_first/1`), and extends it to the
  eliminated variables. Inference only needs satisfiability and one solution: every
  solution gives a valid typing, and the program is accepted iff there is one.
  Options, defaults first, for comparisons: `eliminate: true | false`,
  `tally: :first | :all`.
  """

  @behaviour ProcessTypes.Backend

  alias ProcessTypes.{Backend.Ground, Eliminate, TypeGraph, Types}

  @impl true
  def new(opts) do
    %{
      diags: [],
      deferred: [],
      roles: %{},
      memo: %{},
      solution: %{},
      app: Keyword.get(opts, :app, :compact),
      tally:
        Map.new([eliminate: true, tally: :first], fn {k, v} -> {k, Keyword.get(opts, k, v)} end)
    }
  end

  @impl true
  def mode, do: :infer

  @impl true
  def require_subtype(st, sub, sup, line, diagnostic) do
    if Types.ground?(sub) and Types.ground?(sup),
      do: Ground.require_subtype(st, sub, sup, line, diagnostic),
      else: defer(st, sub, sup, line, diagnostic)
  end

  @impl true
  def apply(st, f, s, o, i, line, diagnostic) do
    if Enum.all?([f, s, o, i], &Types.ground?/1) do
      # The least γ, which tallying would also find.
      Ground.apply(st, f, s, o, i, line, diagnostic)
    else
      diagnostic = fn inst -> diagnostic.(reason(inst, f, s, o, i), inst) end
      {g, st} = fresh(st, "res_#{line}", :res)

      case st.app do
        :literal ->
          {a, st} = fresh(st, "i_app_#{line}", :i)
          {b, st} = fresh(st, "o_app_#{line}", :o)

          st =
            st
            |> defer(b, o, line, diagnostic, [f, s, o, i])
            |> defer(i, a, line, diagnostic, [f, s, o, i])
            |> defer(f, Types.arrow(s, b, a, g), line, diagnostic, [f, s, o, i])

          {g, st}

        :compact ->
          {g, defer(st, f, Types.arrow(s, o, i, g), line, diagnostic, [f, s, o, i])}
      end
    end
  end

  # Why a deferred application fails, judged on the instance printed.
  defp reason(inst, f, s, o, i) do
    case Types.apply(inst.(f), inst.(s), inst.(o), inst.(i)) do
      {:ok, _} -> :unsat
      reason -> reason
    end
  end

  @impl true
  def projections(st, t, n, line, diagnostic) do
    if Types.ground?(t) do
      Ground.projections(st, t, n, line, diagnostic)
    else
      {gs, st} = Enum.map_reduce(1..n//1, st, fn k, st -> fresh(st, "p_#{line}_#{k}", :proj) end)
      {gs, defer(st, t, Types.tuple(gs), line, diagnostic)}
    end
  end

  @impl true
  def annotation(st, occurrence, source, defs, scope) do
    memo(st, {:annotation, occurrence}, fn st ->
      case TypeGraph.decorate(source, defs, scope, prefix(occurrence)) do
        {:ok, t, minted} -> {{:ok, t}, register(st, minted)}
        error -> {error, st}
      end
    end)
  end

  @impl true
  def annotation_arrows(st, occurrence, source, defs, scope) do
    memo(st, {:annotation, occurrence}, fn st ->
      case TypeGraph.decorate_arrows(source, defs, scope, prefix(occurrence)) do
        {:ok, arrows, minted} -> {{:ok, arrows}, register(st, minted)}
        error -> {error, st}
      end
    end)
  end

  @impl true
  def fn_bracket(st, occurrence), do: bracket(st, prefix(occurrence))

  @impl true
  def process_bracket(st, occurrence, t, line, diagnostic) do
    memo(st, {:bracket, occurrence}, fn st ->
      {{o, i}, st} = bracket(st, prefix(occurrence))
      {{o, i}, st |> defer(o, t, line, diagnostic) |> defer(t, i, line, diagnostic)}
    end)
  end

  defp bracket(st, prefix) do
    {o, st} = fresh(st, "o_#{prefix}", :o)
    {i, st} = fresh(st, "i_#{prefix}", :i)
    {{o, i}, st}
  end

  @impl true
  def finish(st, reported) do
    keep =
      reported |> Enum.map(&Types.syntactic_vars/1) |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    opts = Map.put(st.tally, :keep, keep)

    {errors, solution} =
      st.deferred
      |> Enum.reverse()
      |> components()
      |> Enum.reduce({[], %{}}, fn component, {errors, solution} ->
        {more, sigma} = solve(component, st.roles, opts)
        {errors ++ more, Map.merge(solution, sigma)}
      end)

    %{st | diags: Enum.reverse(errors) ++ st.diags, solution: solution}
  end

  @impl true
  def instance(st, t), do: instantiate(st.solution, st.roles).(t)

  # Components: the constraints that share variables, directly or not, in generation
  # order.
  defp components(constraints) do
    constraints
    |> Enum.with_index()
    |> Enum.reduce([], fn {c, k}, components ->
      vars = MapSet.union(Types.vars(c.sub), Types.vars(c.sup))

      {joined, apart} =
        Enum.split_with(components, fn {vs, _} -> not MapSet.disjoint?(vs, vars) end)

      merged =
        Enum.reduce(joined, {vars, [{k, c}]}, fn {vs, cs}, {vars, all} ->
          {MapSet.union(vars, vs), cs ++ all}
        end)

      [merged | apart]
    end)
    |> Enum.map(fn {_vars, cs} -> cs |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)) end)
    |> Enum.sort_by(&hd(&1).line)
  end

  defp solve(constraints, roles, opts) do
    case tally(constraints, opts) do
      [sigma | _] -> {[], sigma}
      [] -> localize([], constraints, [], roles, opts)
    end
  end

  # base has a solution, base ++ rest none.
  defp localize(base, rest, errors, roles, opts) do
    case tally(base ++ rest, opts) do
      [sigma | _] ->
        {Enum.reverse(errors), sigma}

      [] ->
        {before, [culprit | rest]} = Enum.split(rest, first_failure(base, rest, opts))
        base = base ++ before
        # The message instantiates the types that the culprit shows: their variables
        # must keep their most precise solution, so they are not eliminated.
        shown = culprit.shown |> Enum.map(&Types.syntactic_vars/1) |> Enum.reduce(&MapSet.union/2)
        [sigma | _] = tally(base, %{opts | keep: MapSet.union(opts.keep, shown)})
        error = culprit.diagnostic.(instantiate(sigma, roles))
        localize(base, rest, [error | errors], roles, opts)
    end
  end

  # The least k such that base followed by the first k + 1 constraints of rest has no
  # solution.
  defp first_failure(base, rest, opts), do: search(base, rest, 0, length(rest) - 1, opts)

  defp search(_base, _rest, lo, lo, _opts), do: lo

  defp search(base, rest, lo, hi, opts) do
    mid = div(lo + hi, 2)

    if tally(base ++ Enum.take(rest, mid + 1), opts) == [],
      do: search(base, rest, lo, mid, opts),
      else: search(base, rest, mid + 1, hi, opts)
  end

  defp tally(constraints, opts) do
    constraints = Enum.map(constraints, &{&1.sub, &1.sup})

    if opts.eliminate do
      {reduced, eliminations} = Eliminate.eliminate(constraints, opts.keep)

      case solutions(reduced, opts) do
        [] ->
          []

        [sigma | _] ->
          sigma = Eliminate.reconstruct(sigma, eliminations)
          # A safety net: the extended solution must solve the original constraints.
          if satisfies?(sigma, constraints), do: [sigma], else: solutions(constraints, opts)
      end
    else
      solutions(constraints, opts)
    end
  end

  defp solutions(constraints, %{tally: :first}), do: Types.tally_first(constraints)

  defp solutions(constraints, %{tally: :all}), do: Types.tally(constraints)

  defp satisfies?(sigma, constraints) do
    Enum.all?(constraints, fn {s, t} ->
      Types.subtype?(Types.substitute(s, sigma), Types.substitute(t, sigma))
    end)
  end

  defp instantiate(sigma, roles) do
    fn t ->
      t = Types.substitute(t, sigma)
      Types.substitute(t, Map.new(Types.syntactic_vars(t), &{&1, ground(roles[&1])}))
    end
  end

  defp ground(:i), do: Types.term()
  defp ground(_role), do: Types.none()

  # State

  # shown: the types that the diagnostic prints, when it fails.
  defp defer(st, sub, sup, line, diagnostic, shown \\ nil) do
    constraint = %{
      sub: sub,
      sup: sup,
      line: line,
      diagnostic: diagnostic,
      shown: shown || [sub, sup]
    }

    %{st | deferred: [constraint | st.deferred]}
  end

  defp fresh(st, name, role) do
    v = Types.var(String.to_atom(name))
    {v, %{st | roles: Map.put(st.roles, v, role)}}
  end

  defp register(st, minted), do: %{st | roles: Enum.into(minted, st.roles)}

  defp memo(st, key, fun) do
    case st.memo do
      %{^key => value} ->
        {value, st}

      %{} ->
        {value, st} = fun.(st)
        {value, %{st | memo: Map.put(st.memo, key, value)}}
    end
  end

  defp prefix({:def, _module, name, _arity}), do: Atom.to_string(name)
  defp prefix({:fn, line, _column}), do: "fn#{line}"
  defp prefix({:spawn, line, _column}), do: "spawn#{line}"
  defp prefix(:main), do: "main"
end
