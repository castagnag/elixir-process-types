defmodule ProcessTypes.Checker do
  @moduledoc """
  The type checker: the algorithmic rules of Fig. `fig:inference` (Section 8.2 of the
  paper) on the core syntax of `ProcessTypes.Frontend`, in one of the two modes of
  GRAMMAR.md, §9: inference (`ProcessTypes.Backend.Infer`, the default) or ground
  (`ProcessTypes.Backend.Ground`, every decoration known, as in Sections 3–6).

  `synth/4` computes the type of an expression in a context that holds the variable
  environment and the bracket `[o, i]` of the judgment; its last argument is the
  *expected type*, used in ground mode only, to choose the bracket of an unannotated
  `fn` (GRAMMAR.md, §6). Constraints, applications, projections, decorations and the
  brackets of processes go through the backend, which receives every diagnostic as a
  function of the instance to print (`ProcessTypes.Backend`).

  Descr has no integer singleton types, so an integer literal in a pattern is
  approximated in two directions: from above by `integer()` when it refines the
  matched type, from below by `none()` when it is subtracted from later branches or
  counted for exhaustiveness. Both approximations are sound.
  """

  alias ProcessTypes.{Backend, Diagnostic, Printer, TypeSyntax, Types}
  alias ProcessTypes.Frontend.Program

  defmodule Result do
    @moduledoc """
    The outcome of a check: the diagnostics, the annotated functions as
    `%{name, annotation, type, names}` (the annotation as a `TypeSyntax` tree; its type
    with the decorations found, or `false` if it is invalid; the type names visible in
    its module), the type of the main process body (or `nil`), the
    type names visible at the top level, for printing (`ProcessTypes.Printer`), and the
    mode of the check. In inference mode, `constraints` lists the constraints deferred to
    tallying, as `%{sub: s, sup: t, line: line}`, in generation order.
    """
    defstruct diagnostics: [], functions: [], main: nil, names: [], mode: :infer, constraints: []
  end

  @doc """
  Checks a program. Options: `mode: :infer | :ground` (default `:infer`), `split: true`,
  which types a branch once per summand of its refined type (experimental, off by default:
  GRAMMAR.md, §10), and, for inference, `app: :literal | :compact` (see
  `ProcessTypes.Backend.Infer`) and `solve: false`, which skips tallying (to inspect the
  constraints).
  """
  def check(%Program{} = program, opts \\ []) do
    mode = Keyword.get(opts, :mode, :infer)
    backend = if mode == :ground, do: Backend.Ground, else: Backend.Infer
    st = backend.new(opts)
    {sigs, st} = signatures(program, backend, st)

    names =
      Map.new(
        [nil | program.modules],
        &{&1, Printer.names(program.types, &1, program.instances)}
      )

    ctx = %{
      backend: backend,
      program: program,
      sigs: sigs,
      names: names,
      split: Keyword.get(opts, :split, false),
      module: nil,
      env: %{},
      o: nil,
      i: nil
    }

    st =
      program.funs
      |> Map.values()
      |> Enum.sort_by(& &1.line)
      |> Enum.reduce(st, fn fun, st ->
        check_fun(ctx, st, fun, Map.fetch!(sigs, {fun.module, fun.name, fun.arity}))
      end)

    {s0, line, st} =
      case program.self_interface do
        nil ->
          {Types.term(), nil, st}

        {type, line} ->
          {s0, st} = annotation(ctx, st, :main, type, line)
          {s0, line, st}
      end

    # The main process, like a spawned one, runs at a bracket that narrows its
    # interface (rule i-spawn).
    {main, st} =
      if program.main == [] do
        {nil, st}
      else
        {{o, i}, st} =
          backend.process_bracket(st, :main, s0, line, fn inst ->
            Diagnostic.error(
              line,
              "the main process does not keep to its interface #{show(ctx, inst.(s0))}"
            )
          end)

        block(%{ctx | o: o, i: i}, st, program.main, nil)
      end

    st = if Keyword.get(opts, :solve, true), do: backend.finish(st, List.wrap(main)), else: st

    functions =
      for fun <- program.funs |> Map.values() |> Enum.sort_by(& &1.line), fun.annotation do
        sig = Map.fetch!(sigs, {fun.module, fun.name, fun.arity})

        %{
          name: fun_name(fun.module, fun.name, fun.arity),
          annotation: elem(fun.annotation, 0),
          type: sig.arrows != :invalid && backend.instance(st, sig.type),
          names: Map.fetch!(names, fun.module)
        }
      end

    %Result{
      diagnostics: Enum.reverse(st.diags),
      functions: functions,
      main: main && backend.instance(st, main),
      names: Map.fetch!(names, nil),
      mode: mode,
      constraints:
        st
        |> Map.get(:deferred, [])
        |> Enum.reverse()
        |> Enum.map(&Map.take(&1, [:sub, :sup, :line]))
    }
  end

  # The signature of each function: the arrows of its annotation, decorated once for
  # the definition (rule i-abs), and their intersection. A function whose annotation is
  # missing or invalid gets the type none(), and is not checked.
  defp signatures(program, backend, st) do
    Enum.reduce(program.funs, {%{}, st}, fn {key, fun}, {sigs, st} ->
      invalid = %{arrows: :invalid, type: Types.none(), private?: fun.private?}

      {sig, st} =
        case fun.annotation do
          nil ->
            {invalid, st}

          {type, line} ->
            occurrence = {:def, fun.module, fun.name, fun.arity}

            case backend.annotation_arrows(st, occurrence, type, program.types, fun.module) do
              {{:ok, arrows}, st} ->
                case Enum.find(arrows, &(&1.arity != fun.arity)) do
                  nil ->
                    {%{arrows: arrows, type: intersection(arrows), private?: fun.private?}, st}

                  arrow ->
                    message =
                      "the annotation of #{fun.name}/#{fun.arity} has an arrow of arity #{arrow.arity}"

                    {invalid, error(st, line, message)}
                end

              {{:error, message}, st} ->
                {invalid, error(st, line, message)}
            end
        end

      {Map.put(sigs, key, sig), st}
    end)
  end

  defp intersection(arrows) do
    arrows
    |> Enum.map(&Types.arrow(&1.s, &1.o, &1.i, &1.t))
    |> Enum.reduce(&Types.intersection(&2, &1))
  end

  # Rule t-abs for a named function: the clauses are checked once per arrow, as a
  # case on the argument, at the bracket of the arrow.
  defp check_fun(_ctx, st, _fun, %{arrows: :invalid}), do: st

  defp check_fun(ctx, st, fun, sig) do
    name = fun_name(fun.module, fun.name, fun.arity)
    several? = length(sig.arrows) > 1

    Enum.reduce(sig.arrows, st, fn arrow, st ->
      what = if several?, do: "#{name}, under the arrow #{arrow_string(arrow)}", else: name
      ctx = %{ctx | module: fun.module, env: %{}, o: arrow.o, i: arrow.i}

      {_, st} =
        branches(ctx, st, arrow.s, fun.clauses,
          expected: arrow.t,
          bound: {arrow.t, what},
          exhaustive: {fun.line, "the clauses of #{what}"}
        )

      st
    end)
  end

  # Clauses: rules t-case and t-receive. The j-th clause is typed under the refined
  # type r_j = (t ∧ ⌈p_j⌉) ∖ ⋁_{h<j} ⌈p_h⌉, and skipped when r_j is empty, that is,
  # empty whatever its type variables stand for.
  defp branches(ctx, st, t, clauses, opts) do
    {covered, types, st} =
      Enum.reduce(clauses, {Types.none(), [], st}, fn {meta, patterns, body},
                                                      {covered, types, st} ->
        p = single(patterns)
        r = Types.difference(Types.intersection(t, upper(p)), covered)
        covered = Types.union(covered, lower(p))

        if Types.empty?(r) do
          {covered, types, st}
        else
          {envs, st} = penv(ctx, st, r, p, meta[:line])

          {u, st} =
            per_env(st, envs, fn env, st ->
              block(%{ctx | env: Map.merge(ctx.env, env)}, st, body, opts[:expected])
            end)

          st =
            case opts[:bound] do
              nil ->
                st

              {bound, what} ->
                ctx.backend.require_subtype(st, u, bound, meta[:line], fn inst ->
                  Diagnostic.error(
                    meta[:line],
                    "#{what}: this clause returns #{show(ctx, inst.(u))}, which is not a subtype of #{show(ctx, inst.(bound))}"
                  )
                end)
            end

          {covered, [u | types], st}
        end
      end)

    st =
      case opts[:exhaustive] do
        nil ->
          st

        {line, what} ->
          ctx.backend.require_subtype(st, t, covered, line, fn inst ->
            Diagnostic.error(
              line,
              "#{what} do not cover #{show(ctx, Types.difference(inst.(t), covered))}"
            )
          end)
      end

    {Types.union_all(types), st}
  end

  # What the scope of a pattern types once per environment: the union of the results.
  defp per_env(st, [env], typing), do: typing.(env, st)

  defp per_env(st, envs, typing) do
    {types, st} = Enum.map_reduce(envs, st, typing)
    {Types.union_all(types), st}
  end

  defp single([p]), do: p
  defp single(ps), do: {:ptuple, [], ps}

  defp upper({:pvar, _, _}), do: Types.term()
  defp upper({:pwild, _}), do: Types.term()
  defp upper({:patom, _, a}), do: Types.atom([a])
  defp upper({:pint, _, _}), do: Types.integer()
  defp upper({:ptest, _, t}), do: t
  defp upper({:ptuple, _, ps}), do: Types.tuple(Enum.map(ps, &upper/1))
  defp upper({:pand, _, p1, p2}), do: Types.intersection(upper(p1), upper(p2))

  defp lower({:pint, _, _}), do: Types.none()
  defp lower({:ptuple, _, ps}), do: Types.tuple(Enum.map(ps, &lower/1))
  defp lower({:pand, _, p1, p2}), do: Types.intersection(lower(p1), lower(p2))
  defp lower(p), do: upper(p)

  # The pattern environments, one per summand of the matched type that the pattern splits
  # (GRAMMAR.md, §10); only one without the option split.
  defp penv(ctx, st, t, p, line) do
    {envs, st} =
      ctx
      |> summands(t, p)
      |> Enum.map_reduce(st, fn summand, st -> pattern_env(ctx, st, summand, p, line) end)

    {envs |> Enum.concat() |> Enum.uniq(), st}
  end

  defp summands(%{split: true}, t, p) do
    n = tuple_arity(p)
    if n && binders(p) >= 2, do: Types.tuple_summands(t, n), else: [t]
  end

  defp summands(_ctx, t, _p), do: [t]

  defp tuple_arity({:ptuple, _, ps}), do: length(ps)
  defp tuple_arity({:pand, _, p1, p2}), do: tuple_arity(p1) || tuple_arity(p2)
  defp tuple_arity(_p), do: nil

  defp binders({:pvar, _, _}), do: 1
  defp binders({:ptuple, _, ps}), do: ps |> Enum.map(&binders/1) |> Enum.sum()
  defp binders({:pand, _, p1, p2}), do: binders(p1) + binders(p2)
  defp binders(_p), do: 0

  # The rules pe-var, pe-test, pe-and and pe-tuple of Section 8.2.1. The constraint of
  # pe-test holds whenever the matched type is a refined type r_j, which is below ⌈p_j⌉;
  # it is emitted as the rule states it.
  defp pattern_env(_ctx, st, t, {:pvar, _, x}, _line), do: {[%{x => t}], st}
  defp pattern_env(_ctx, st, _t, {:pwild, _}, _line), do: {[%{}], st}

  defp pattern_env(ctx, st, t, {:ptuple, _, ps}, line) do
    {components, st} =
      ctx.backend.projections(st, t, length(ps), line, fn inst ->
        Diagnostic.error(line, "this pattern cannot match #{show(ctx, inst.(t))}")
      end)

    ps
    |> Enum.zip(components)
    |> Enum.reduce({[%{}], st}, fn {p, component}, {envs, st} ->
      {envs_k, st} = penv(ctx, st, component, p, line)
      {merge_envs(envs, envs_k), st}
    end)
  end

  defp pattern_env(ctx, st, t, {:pand, _, p1, p2}, line) do
    {envs1, st} = pattern_env(ctx, st, t, p1, line)
    {envs2, st} = pattern_env(ctx, st, t, p2, line)
    {merge_envs(envs1, envs2), st}
  end

  defp pattern_env(ctx, st, t, p, line) do
    tau = upper(p)

    st =
      ctx.backend.require_subtype(st, t, tau, line, fn inst ->
        Diagnostic.error(line, "this pattern cannot match #{show(ctx, inst.(t))}")
      end)

    {[%{}], st}
  end

  defp merge_envs(envs1, envs2), do: for(e1 <- envs1, e2 <- envs2, do: Map.merge(e1, e2))

  # Blocks: a statement p = e is a case with one exhaustive clause whose scope is the
  # rest of the block.
  defp block(ctx, st, stmts, expected), do: statements(ctx, st, stmts, Types.none(), expected)

  defp statements(_ctx, st, [], type, _expected), do: {type, st}

  defp statements(ctx, st, [{:expr, e} | rest], _type, expected) do
    {u, st} = synth(ctx, st, e, if(rest == [], do: expected))
    statements(ctx, st, rest, u, expected)
  end

  defp statements(ctx, st, [{:match, meta, p, e} | rest], _type, expected) do
    {u, st} = synth(ctx, st, e, nil)

    st =
      ctx.backend.require_subtype(st, u, lower(p), meta[:line], fn inst ->
        Diagnostic.error(
          meta[:line],
          "this match may fail: #{show(ctx, Types.difference(inst.(u), lower(p)))} does not match the pattern"
        )
      end)

    r = Types.intersection(u, upper(p))
    {envs, st} = penv(ctx, st, r, p, meta[:line])

    per_env(st, envs, fn env, st ->
      statements(%{ctx | env: Map.merge(ctx.env, env)}, st, rest, r, expected)
    end)
  end

  # Expressions

  defp synth(ctx, st, {:var, meta, x}, _expected) do
    case Map.fetch(ctx.env, x) do
      {:ok, t} -> {t, st}
      :error -> {Types.none(), error(st, meta[:line], "undefined variable #{x}")}
    end
  end

  defp synth(_ctx, st, {:atom, _, a}, _expected), do: {Types.atom([a]), st}
  defp synth(_ctx, st, {:int, _, _}, _expected), do: {Types.integer(), st}

  # The expected type of a component is that of the tuple, restricted by the types of
  # the components that precede it.
  defp synth(ctx, st, {:tuple, _, es}, expected) do
    n = length(es)

    expected =
      if expected, do: Types.intersection(expected, Types.tuple(List.duplicate(Types.term(), n)))

    expected = if expected && not Types.empty?(expected), do: expected

    {types, st} =
      es
      |> Enum.with_index()
      |> Enum.reduce({[], st}, fn {e, k}, {types, st} ->
        exp_k =
          if expected do
            prefix = Enum.reverse(types)

            restricted =
              Types.intersection(
                expected,
                Types.tuple(prefix ++ List.duplicate(Types.term(), n - k))
              )

            if not Types.empty?(restricted), do: Types.tuple_component(restricted, k)
          end

        {t, st} = synth(ctx, st, e, exp_k)
        {[t | types], st}
      end)

    {Types.tuple(Enum.reverse(types)), st}
  end

  # Rule t-self.
  defp synth(ctx, st, {:self, _}, _expected), do: {Types.pid(ctx.o), st}

  # Rule t-plus, for + - * div rem and unary minus; comparisons have type boolean().
  defp synth(ctx, st, {:arith, meta, op, a, b}, _expected) do
    {ta, st} = synth(ctx, st, a, nil)
    {tb, st} = synth(ctx, st, b, nil)
    st = require_integer(ctx, st, ta, meta, "the left operand of #{op}")
    st = require_integer(ctx, st, tb, meta, "the right operand of #{op}")
    {Types.integer(), st}
  end

  defp synth(ctx, st, {:neg, meta, a}, _expected) do
    {ta, st} = synth(ctx, st, a, nil)
    {Types.integer(), require_integer(ctx, st, ta, meta, "the operand of -")}
  end

  defp synth(ctx, st, {:cmp, _, _, a, b}, _expected) do
    {_, st} = synth(ctx, st, a, nil)
    {_, st} = synth(ctx, st, b, nil)
    {Types.boolean(), st}
  end

  # Rule t-app, for named functions and closures.
  defp synth(ctx, st, {:call, meta, target, args}, _expected) do
    {module, f} =
      case target do
        {:local, f} -> {ctx.module, f}
        {:remote, module, f} -> {module, f}
      end

    name = fun_name(module, f, length(args))

    case Map.fetch(ctx.sigs, {module, f, length(args)}) do
      {:ok, %{private?: true}} when module != ctx.module ->
        {_, st} = synth_all(ctx, st, args)
        {Types.none(), error(st, meta[:line], "#{name} is private")}

      {:ok, %{arrows: :invalid}} ->
        {_, st} = synth_all(ctx, st, args)
        {Types.none(), st}

      {:ok, sig} ->
        app(ctx, st, sig.type, args, meta, name)

      :error ->
        {_, st} = synth_all(ctx, st, args)
        {Types.none(), error(st, meta[:line], "undefined function #{name}")}
    end
  end

  defp synth(ctx, st, {:apply, meta, e, args}, _expected) do
    {f, st} = synth(ctx, st, e, nil)
    app(ctx, st, f, args, meta, "this closure")
  end

  # Rule t-abs for an fn without annotation. In inference mode it runs at fresh
  # decorations (rule i-abs); in ground mode, at the bracket of the expected type when
  # this is a single arrow of arity 0, at [none(), term()] otherwise (GRAMMAR.md, §6).
  defp synth(ctx, st, {:fn, meta, nil, [{_, [], body}]}, expected) do
    case ctx.backend.fn_bracket(st, {:fn, meta[:line], meta[:column]}) do
      {{o, i}, st} ->
        {u, st} = block(%{ctx | o: o, i: i}, st, body, nil)
        {Types.arrow(Types.tuple([]), o, i, u), st}

      {nil, st} ->
        {o, i, exp} =
          with true <- expected != nil,
               {:ok, {s, o, i, u}} <-
                 Types.arrow_parts(Types.intersection(expected, Types.fun())),
               true <- Types.equal?(s, Types.tuple([])) do
            {o, i, u}
          else
            _ -> {Types.none(), Types.term(), nil}
          end

        {u, st} = block(%{ctx | o: o, i: i}, st, body, exp)
        {Types.arrow(Types.tuple([]), o, i, u), st}
    end
  end

  defp synth(_ctx, st, {:fn, meta, nil, _clauses}, _expected),
    do:
      {Types.none(),
       error(st, meta[:line], "an fn with parameters needs a $ annotation on the line before")}

  defp synth(ctx, st, {:fn, meta, {type, line}, clauses}, _expected) do
    arity = clauses |> hd() |> elem(1) |> length()
    occurrence = {:fn, meta[:line], meta[:column]}

    case ctx.backend.annotation_arrows(st, occurrence, type, ctx.program.types, ctx.module) do
      {{:ok, arrows}, st} ->
        case Enum.find(arrows, &(&1.arity != arity)) do
          nil ->
            st =
              Enum.reduce(arrows, st, fn arrow, st ->
                what = "this fn, under the arrow #{arrow_string(arrow)}"

                {_, st} =
                  branches(%{ctx | o: arrow.o, i: arrow.i}, st, arrow.s, clauses,
                    expected: arrow.t,
                    bound: {arrow.t, what},
                    exhaustive: {meta[:line], "the clauses of #{what}"}
                  )

                st
              end)

            {intersection(arrows), st}

          arrow ->
            {Types.none(),
             error(
               st,
               line,
               "this fn has arity #{arity}, its annotation an arrow of arity #{arrow.arity}"
             )}
        end

      {{:error, message}, st} ->
        {Types.none(), error(st, line, message)}
    end
  end

  defp synth(ctx, st, {:case, meta, e, clauses}, expected) do
    {t, st} = synth(ctx, st, e, nil)

    branches(ctx, st, t, clauses,
      expected: expected,
      exhaustive: {meta[:line], "the clauses of this case"}
    )
  end

  # Rule t-receive: the mailbox is read at the input decoration i.
  defp synth(ctx, st, {:receive, _meta, clauses}, expected),
    do: branches(ctx, st, ctx.i, clauses, expected: expected)

  # Rule t-send. When the type of the target is known (it has no variables) and is no
  # process type, the error is reported at once; otherwise the constraint p ≤ pid(m)
  # decides. In ground mode, the expected type of the message is the interface of the
  # target.
  defp synth(ctx, st, {:send, meta, target, message}, _expected) do
    {p, st} = synth(ctx, st, target, nil)
    known? = Types.ground?(p)
    process? = known? and Types.subtype?(p, Types.pid())

    st =
      if known? and not process?,
        do: error(st, meta[:line], not_a_process(ctx, p)),
        else: st

    expected = if process? and ctx.backend.mode() == :ground, do: Types.interface(p)
    {m, st} = synth(ctx, st, message, expected)

    st =
      if process? or not known? do
        ctx.backend.require_subtype(st, p, Types.pid(m), meta[:line], fn inst ->
          {p, m} = {inst.(p), inst.(m)}

          if Types.subtype?(p, Types.pid()),
            do:
              Diagnostic.error(
                meta[:line],
                "send: the target accepts #{show(ctx, Types.interface(p))}, not #{show(ctx, m)}"
              ),
            else: Diagnostic.error(meta[:line], not_a_process(ctx, p))
        end)
      else
        st
      end

    {m, st}
  end

  # Rule t-spawn (i-spawn): the body runs at the bracket that the backend gives for the
  # declared interface t, [t, t] in ground mode.
  defp synth(ctx, st, {:spawn, meta, {type, line}, target}, _expected) do
    occurrence = {:spawn, meta[:line], meta[:column]}
    {s, st} = annotation(ctx, st, occurrence, type, line)

    {{o, i}, st} =
      ctx.backend.process_bracket(st, occurrence, s, meta[:line], fn inst ->
        Diagnostic.error(
          meta[:line],
          "spawn: the process does not keep to its interface #{show(ctx, inst.(s))}"
        )
      end)

    st =
      case target do
        {:body, body} ->
          {_, st} = block(%{ctx | o: o, i: i}, st, body, nil)
          st

        {:expr, e} ->
          {f, st} = synth(ctx, st, e, nil)

          {_, st} =
            ctx.backend.apply(st, f, Types.tuple([]), o, i, meta[:line], fn _reason, inst ->
              Diagnostic.error(
                meta[:line],
                "spawn: a function of type #{show(ctx, inst.(f))} cannot run in a process of interface #{show(ctx, inst.(s))}"
              )
            end)

          st
      end

    {Types.pid(s), st}
  end

  defp synth(ctx, st, {:block, _, stmts}, expected), do: block(ctx, st, stmts, expected)

  defp not_a_process(ctx, p),
    do: "send: the target has type #{show(ctx, p)}, which is not a process type"

  # Applications

  defp app(ctx, st, f, args, meta, name) do
    n = length(args)

    expected =
      if ctx.backend.mode() == :ground,
        do: expected_arguments(f, n),
        else: List.duplicate(nil, n)

    {types, st} =
      args
      |> Enum.zip(expected)
      |> Enum.map_reduce(st, fn {e, exp}, st -> synth(ctx, st, e, exp) end)

    s = if n == 1, do: hd(types), else: Types.tuple(types)
    {o, i} = {ctx.o, ctx.i}

    ctx.backend.apply(st, f, s, o, i, meta[:line], fn reason, inst ->
      Diagnostic.error(
        meta[:line],
        application_error(ctx, reason, name, inst.(f), inst.(s), inst.(o), inst.(i))
      )
    end)
  end

  defp expected_arguments(f, n) do
    domain = Types.value_domain(f)

    case n do
      1 ->
        [domain]

      _ ->
        domain = Types.intersection(domain, Types.tuple(List.duplicate(Types.term(), n)))

        if Types.empty?(domain),
          do: List.duplicate(nil, n),
          else: for(k <- 0..(n - 1)//1, do: Types.tuple_component(domain, k))
    end
  end

  defp application_error(ctx, :badfun, name, f, _s, _o, _i),
    do: "#{name} is not a function: it has type #{show(ctx, f)}"

  defp application_error(ctx, :badarg, name, f, s, o, i) do
    # At the bracket [term(), none()] every arrow can be called.
    case Types.apply(f, s, Types.term(), Types.none()) do
      {:ok, _} ->
        "#{name} cannot be applied to #{show(ctx, s)} at the bracket " <>
          "[#{show(ctx, o)}, #{show(ctx, i)}]: its type is #{show(ctx, f)}, " <>
          "and an arrow (s -> t)@[o', i'] can be called at [o, i] only if o' ≤ o and i ≤ i'"

      _ ->
        "#{name} cannot be applied to #{show(ctx, s)}: its type is #{show(ctx, f)}"
    end
  end

  defp application_error(ctx, :unsat, name, f, s, o, i) do
    "#{name} cannot be applied to #{show(ctx, s)} at the bracket " <>
      "[#{show(ctx, o)}, #{show(ctx, i)}] consistently with the rest of the program: " <>
      "its type is #{show(ctx, f)}"
  end

  defp synth_all(ctx, st, es), do: Enum.map_reduce(es, st, &synth(ctx, &2, &1, nil))

  defp require_integer(ctx, st, t, meta, what) do
    ctx.backend.require_subtype(st, t, Types.integer(), meta[:line], fn inst ->
      Diagnostic.error(meta[:line], "#{what} has type #{show(ctx, inst.(t))}, not integer()")
    end)
  end

  # Helpers

  # The type of an interface annotation at an occurrence; term() if it is invalid.
  defp annotation(ctx, st, occurrence, type, line) do
    case ctx.backend.annotation(st, occurrence, type, ctx.program.types, ctx.module) do
      {{:ok, t}, st} -> {t, st}
      {{:error, message}, st} -> {Types.term(), error(st, line, message)}
    end
  end

  defp error(st, line, message), do: %{st | diags: [Diagnostic.error(line, message) | st.diags]}

  # Types in messages are printed with the names visible in the current module.
  defp show(ctx, t), do: Printer.to_string(t, Map.get(ctx.names, ctx.module, []))
  defp arrow_string(arrow), do: TypeSyntax.to_string(arrow.source)

  defp fun_name(nil, f, n), do: "#{f}/#{n}"
  defp fun_name(module, f, n), do: "#{inspect(module)}.#{f}/#{n}"
end
