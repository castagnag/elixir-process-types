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

  With the option `record: true`, set by reconstruction mode only (GRAMMAR.md, §11), the
  backend also keeps what `ProcessTypes.Reconstruct` needs: the kind of each constraint
  (`:send`, `{:app, head, f, s, o, i, γ}`), the uses of rule i-receive, and the
  unannotated `spawn`s, each with a placeholder among the constraints, where
  `finish_with/4` puts the constraints of rule i-spawn once the interface is known.
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
      record: Keyword.get(opts, :record, false),
      kind: nil,
      events: [],
      captures: %{},
      pre: %{},
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
      do: Ground.require_subtype(st, sub, sup, line, diagnostic) |> unkind(),
      else: defer(st, sub, sup, line, diagnostic) |> unkind()
  end

  # The kind noted by the checker describes one constraint only.
  defp unkind(%{kind: nil} = st), do: st
  defp unkind(st), do: %{st | kind: nil}

  @impl true
  def apply(st, f, s, o, i, line, diagnostic) do
    if Enum.all?([f, s, o, i], &Types.ground?/1) do
      # The least γ, which tallying would also find.
      {u, st} = Ground.apply(st, f, s, o, i, line, diagnostic)
      {u, unkind(st)}
    else
      diagnostic = fn inst -> diagnostic.(reason(inst, f, s, o, i), inst) end
      {g, st} = fresh(st, "res_#{line}", :res)

      st =
        case st.kind do
          {:app, head} -> %{st | kind: {:app, head, f, s, o, i, g}}
          _ -> st
        end

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
          {g, defer(st, f, Types.arrow(s, o, i, g), line, diagnostic, [f, s, o, i]) |> unkind()}
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

  @impl true
  def spawn_alt(st, occurrence, line) do
    memo(st, {:spawn_alt, occurrence}, fn st ->
      {{o, i}, st} = bracket(st, prefix(occurrence))
      {g, st} = fresh(st, "pid_#{prefix(occurrence)}", :pid)
      info = %{occurrence: occurrence, line: line, o: o, i: i, pid: g}
      placeholder = %{placeholder: occurrence, line: line}

      {{{o, i}, g},
       %{st | events: [{:spawn_alt, info} | st.events], deferred: [placeholder | st.deferred]}}
    end)
    |> then(fn {{bracket, g}, st} -> {bracket, g, st} end)
  end

  @impl true
  def capture(%{record: false} = st, r, _line), do: {r, st}

  def capture(st, r, line) do
    {x, st} = fresh(st, "x_#{line}", :proj)
    st = %{st | captures: Map.put(st.captures, x, r)}

    {x,
     defer(st, r, x, line, fn _inst ->
       ProcessTypes.Diagnostic.error(line, "this branch cannot bind its variable")
     end)}
  end

  @impl true
  def resolved(%{captures: captures}, t) when captures == %{}, do: t
  def resolved(st, t), do: Types.substitute(t, st.captures)

  @impl true
  def note(%{record: false} = st, _event), do: st
  def note(st, {:kind, kind}), do: %{st | kind: kind}
  def note(st, event), do: %{st | events: [event | st.events]}

  @doc "The constraints deferred so far, in generation order, with the placeholders."
  def deferred(st), do: Enum.reverse(st.deferred)

  @doc "What `note/2` and `spawn_alt/3` recorded, in generation order."
  def events(st), do: Enum.reverse(st.events)

  @doc "The role of each variable minted: `:o`, `:i`, `:res`, `:proj` or `:pid`."
  def roles(st), do: st.roles

  @doc """
  The checking step of the reconstruction: `pre` maps pid variables to the interfaces
  found; each placeholder of an occurrence in `brackets` (a map from occurrences to
  lists of constraints, as maps with `:sub`, `:sup`, `:line` and `:diagnostic`) is replaced
  by these constraints, the others are dropped; then as `finish/2`.
  """
  def finish_with(st, pre, brackets, reported) do
    deferred =
      Enum.flat_map(st.deferred, fn
        %{placeholder: occurrence} ->
          brackets
          |> Map.get(occurrence, [])
          |> Enum.map(&Map.merge(%{shown: [&1.sub, &1.sup], kind: nil}, &1))
          |> Enum.reverse()

        c ->
          [%{c | sub: Types.substitute(c.sub, pre), sup: Types.substitute(c.sup, pre)}]
      end)

    finish(%{st | deferred: deferred, pre: pre}, Enum.map(reported, &Types.substitute(&1, pre)))
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

    opts = st.tally |> Map.put(:keep, keep) |> Map.put(:pre, st.pre)

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
  def instance(st, t), do: instantiate(st.solution, st.roles, st.pre).(t)

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

  defp solve(constraints, roles, opts), do: localize([], constraints, [], roles, opts)

  # base has a solution. If base ++ rest has none, the first constraint of rest that
  # makes it unsatisfiable is reported and removed, and so on with what follows it.
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
        error = culprit.diagnostic.(instantiate(sigma, roles, opts.pre))
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

  # pre: the interfaces that the reconstruction substituted for the pid variables.
  defp instantiate(sigma, roles, pre) do
    sigma = if pre == %{}, do: sigma, else: Map.merge(sigma, pre)

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
      shown: shown || [sub, sup],
      kind: st.kind
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
