defmodule ProcessTypes.Checker do
  @moduledoc """
  The type checker: the algorithmic rules of Section 8.2.2 of the paper with every
  decoration known (Sections 3–6), on the core syntax of `ProcessTypes.Frontend`.

  `synth/4` computes the type of an expression in a context that holds the variable
  environment and the bracket `[o, i]` of the judgment; its last argument is the
  *expected type*, used only to choose the bracket of an unannotated `fn`
  (GRAMMAR.md, §6). Constraints go through the backend (`ProcessTypes.Backend`).

  Descr has no integer singleton types, so an integer literal in a pattern is
  approximated in two directions: from above by `integer()` when it refines the
  matched type, from below by `none()` when it is subtracted from later branches or
  counted for exhaustiveness. Both approximations are sound.
  """

  alias ProcessTypes.{Diagnostic, TypeSyntax, Types}
  alias ProcessTypes.Frontend.Program

  defmodule Result do
    @moduledoc """
    The outcome of a check: the diagnostics, the annotated functions as
    `{name, annotation}` strings, and the type of the main process body (or `nil`).
    """
    defstruct diagnostics: [], functions: [], main: nil
  end

  @doc "Checks a program; the backend defaults to `ProcessTypes.Backend.Ground`."
  def check(%Program{} = program, backend \\ ProcessTypes.Backend.Ground) do
    st = %{diags: []}
    {sigs, st} = signatures(program, st)
    ctx = %{backend: backend, program: program, sigs: sigs, module: nil, env: %{}, o: nil, i: nil}

    st =
      program.funs
      |> Map.values()
      |> Enum.sort_by(& &1.line)
      |> Enum.reduce(st, fn fun, st ->
        check_fun(ctx, st, fun, Map.fetch!(sigs, {fun.module, fun.name, fun.arity}))
      end)

    {s0, st} =
      case program.self_interface do
        nil -> {Types.term(), st}
        {type, line} -> descr(st, type, program.types, nil, line, Types.term())
      end

    {main, st} =
      if program.main == [],
        do: {nil, st},
        else: block(%{ctx | o: s0, i: s0}, st, program.main, nil)

    functions =
      for fun <- program.funs |> Map.values() |> Enum.sort_by(& &1.line), fun.annotation do
        {fun_name(fun.module, fun.name, fun.arity), TypeSyntax.to_string(elem(fun.annotation, 0))}
      end

    %Result{diagnostics: Enum.reverse(st.diags), functions: functions, main: main}
  end

  # The signature of each function: the arrows of its annotation and their
  # intersection. A function whose annotation is missing or invalid gets the type
  # none(), and is not checked.
  defp signatures(program, st) do
    Enum.reduce(program.funs, {%{}, st}, fn {key, fun}, {sigs, st} ->
      {sig, st} =
        case fun.annotation do
          nil ->
            {%{arrows: :invalid, type: Types.none(), private?: fun.private?}, st}

          {type, line} ->
            case TypeSyntax.arrows(type, program.types, fun.module) do
              {:ok, arrows} ->
                case Enum.find(arrows, &(&1.arity != fun.arity)) do
                  nil ->
                    type =
                      arrows
                      |> Enum.map(&Types.arrow(&1.s, &1.o, &1.i, &1.t))
                      |> Enum.reduce(&Types.intersection(&2, &1))

                    {%{arrows: arrows, type: type, private?: fun.private?}, st}

                  arrow ->
                    message =
                      "the annotation of #{fun.name}/#{fun.arity} has an arrow of arity #{arrow.arity}"

                    {%{arrows: :invalid, type: Types.none(), private?: fun.private?},
                     error(st, line, message)}
                end

              {:error, message} ->
                {%{arrows: :invalid, type: Types.none(), private?: fun.private?},
                 error(st, line, message)}
            end
        end

      {Map.put(sigs, key, sig), st}
    end)
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
  # type r_j = (t ∧ ⌈p_j⌉) ∖ ⋁_{h<j} ⌈p_h⌉, and skipped when r_j is empty.
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
          {env, st} = penv(ctx, st, r, p)
          {u, st} = block(%{ctx | env: Map.merge(ctx.env, env)}, st, body, opts[:expected])

          st =
            case opts[:bound] do
              nil ->
                st

              {bound, what} ->
                ctx.backend.require_subtype(st, u, bound, fn ->
                  Diagnostic.error(
                    meta[:line],
                    "#{what}: this clause returns #{show(u)}, which is not a subtype of #{show(bound)}"
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
          ctx.backend.require_subtype(st, t, covered, fn ->
            Diagnostic.error(line, "#{what} do not cover #{show(Types.difference(t, covered))}")
          end)
      end

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

  # The pattern environment ⟨t/p⟩ (Figure 4 of the paper; rule pe-tuple projects).
  defp penv(_ctx, st, t, {:pvar, _, x}), do: {%{x => t}, st}

  defp penv(ctx, st, t, {:ptuple, _, ps}) do
    ps
    |> Enum.with_index()
    |> Enum.reduce({%{}, st}, fn {p, k}, {env, st} ->
      {component, st} = ctx.backend.project(st, t, k)
      {env_k, st} = penv(ctx, st, component, p)
      {Map.merge(env, env_k), st}
    end)
  end

  defp penv(ctx, st, t, {:pand, _, p1, p2}) do
    {env1, st} = penv(ctx, st, t, p1)
    {env2, st} = penv(ctx, st, t, p2)
    {Map.merge(env1, env2), st}
  end

  defp penv(_ctx, st, _t, _p), do: {%{}, st}

  # Blocks: a statement p = e is a case with one exhaustive clause whose scope is the
  # rest of the block.
  defp block(ctx, st, stmts, expected) do
    last = length(stmts) - 1

    {_, type, st} =
      stmts
      |> Enum.with_index()
      |> Enum.reduce({ctx, Types.none(), st}, fn
        {{:expr, e}, k}, {ctx, _, st} ->
          {u, st} = synth(ctx, st, e, if(k == last, do: expected))
          {ctx, u, st}

        {{:match, meta, p, e}, _}, {ctx, _, st} ->
          {u, st} = synth(ctx, st, e, nil)

          st =
            ctx.backend.require_subtype(st, u, lower(p), fn ->
              Diagnostic.error(
                meta[:line],
                "this match may fail: #{show(Types.difference(u, lower(p)))} does not match the pattern"
              )
            end)

          r = Types.intersection(u, upper(p))
          {env, st} = penv(ctx, st, r, p)
          {%{ctx | env: Map.merge(ctx.env, env)}, r, st}
      end)

    {type, st}
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

  # Rule t-plus, for + - * and unary minus; comparisons have type boolean().
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

  # Rule t-abs for an fn. Without annotation, an fn without parameters is typed at
  # the bracket of the expected type when this is a single arrow of arity 0, at
  # [none(), term()] otherwise (GRAMMAR.md, §6).
  defp synth(ctx, st, {:fn, _meta, nil, [{_, [], body}]}, expected) do
    {o, i, exp} =
      with true <- expected != nil,
           {:ok, {s, o, i, u}} <- Types.arrow_parts(Types.intersection(expected, Types.fun())),
           true <- Types.equal?(s, Types.tuple([])) do
        {o, i, u}
      else
        _ -> {Types.none(), Types.term(), nil}
      end

    {u, st} = block(%{ctx | o: o, i: i}, st, body, exp)
    {Types.arrow(Types.tuple([]), o, i, u), st}
  end

  defp synth(_ctx, st, {:fn, meta, nil, _clauses}, _expected),
    do:
      {Types.none(),
       error(st, meta[:line], "an fn with parameters needs a $ annotation on the line before")}

  defp synth(ctx, st, {:fn, meta, {type, line}, clauses}, _expected) do
    arity = clauses |> hd() |> elem(1) |> length()

    case TypeSyntax.arrows(type, ctx.program.types, ctx.module) do
      {:ok, arrows} ->
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

            type =
              arrows
              |> Enum.map(&Types.arrow(&1.s, &1.o, &1.i, &1.t))
              |> Enum.reduce(&Types.intersection(&2, &1))

            {type, st}

          arrow ->
            {Types.none(),
             error(
               st,
               line,
               "this fn has arity #{arity}, its annotation an arrow of arity #{arrow.arity}"
             )}
        end

      {:error, message} ->
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

  # Rule t-send: the expected type of the message is the interface of the target.
  defp synth(ctx, st, {:send, meta, target, message}, _expected) do
    {p, st} = synth(ctx, st, target, nil)
    process? = Types.subtype?(p, Types.pid())

    st =
      if process?,
        do: st,
        else:
          error(
            st,
            meta[:line],
            "send: the target has type #{show(p)}, which is not a process type"
          )

    {m, st} = synth(ctx, st, message, if(process?, do: Types.interface(p)))

    st =
      if process? do
        ctx.backend.require_subtype(st, p, Types.pid(m), fn ->
          Diagnostic.error(
            meta[:line],
            "send: the target accepts #{show(Types.interface(p))}, not #{show(m)}"
          )
        end)
      else
        st
      end

    {m, st}
  end

  # Rule t-spawn: the body runs at the bracket [t, t] of the declared interface t.
  defp synth(ctx, st, {:spawn, meta, {type, line}, target}, _expected) do
    {s, st} = descr(st, type, ctx.program.types, ctx.module, line, Types.term())

    st =
      case target do
        {:body, body} ->
          {_, st} = block(%{ctx | o: s, i: s}, st, body, nil)
          st

        {:expr, e} ->
          {f, st} = synth(ctx, st, e, nil)

          {_, st} =
            ctx.backend.apply(st, f, Types.tuple([]), s, s, fn _ ->
              Diagnostic.error(
                meta[:line],
                "spawn: a function of type #{show(f)} cannot run in a process of interface #{show(s)}"
              )
            end)

          st
      end

    {Types.pid(s), st}
  end

  defp synth(ctx, st, {:block, _, stmts}, expected), do: block(ctx, st, stmts, expected)

  # Applications

  defp app(ctx, st, f, args, meta, name) do
    n = length(args)
    domain = Types.value_domain(f)

    expected =
      case n do
        1 ->
          [domain]

        _ ->
          domain = Types.intersection(domain, Types.tuple(List.duplicate(Types.term(), n)))

          if Types.empty?(domain),
            do: List.duplicate(nil, n),
            else: for(k <- 0..(n - 1)//1, do: Types.tuple_component(domain, k))
      end

    {types, st} =
      args
      |> Enum.zip(expected)
      |> Enum.map_reduce(st, fn {e, exp}, st -> synth(ctx, st, e, exp) end)

    s = if n == 1, do: hd(types), else: Types.tuple(types)

    ctx.backend.apply(st, f, s, ctx.o, ctx.i, fn reason ->
      Diagnostic.error(meta[:line], application_error(reason, name, f, s, ctx.o, ctx.i))
    end)
  end

  defp application_error(:badfun, name, f, _s, _o, _i),
    do: "#{name} is not a function: it has type #{show(f)}"

  defp application_error(:badarg, name, f, s, o, i) do
    # At the bracket [term(), none()] every arrow can be called.
    case Types.apply(f, s, Types.term(), Types.none()) do
      {:ok, _} ->
        "#{name} cannot be applied to #{show(s)} at the bracket [#{show(o)}, #{show(i)}]: its type is #{show(f)}, " <>
          "and an arrow (s -> t)@[o', i'] can be called at [o, i] only if o' ≤ o and i ≤ i'"

      _ ->
        "#{name} cannot be applied to #{show(s)}: its type is #{show(f)}"
    end
  end

  defp synth_all(ctx, st, es), do: Enum.map_reduce(es, st, &synth(ctx, &2, &1, nil))

  defp require_integer(ctx, st, t, meta, what) do
    ctx.backend.require_subtype(st, t, Types.integer(), fn ->
      Diagnostic.error(meta[:line], "#{what} has type #{show(t)}, not integer()")
    end)
  end

  # Helpers

  defp descr(st, type, defs, scope, line, fallback) do
    case TypeSyntax.to_descr(type, defs, scope) do
      {:ok, t} -> {t, st}
      {:error, message} -> {fallback, error(st, line, message)}
    end
  end

  defp error(st, line, message), do: %{st | diags: [Diagnostic.error(line, message) | st.diags]}

  defp show(t), do: Types.to_string(t)
  defp arrow_string(arrow), do: TypeSyntax.to_string(arrow.source)

  defp fun_name(nil, f, n), do: "#{f}/#{n}"
  defp fun_name(module, f, n), do: "#{inspect(module)}.#{f}/#{n}"
end
