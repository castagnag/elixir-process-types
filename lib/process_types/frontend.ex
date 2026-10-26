defmodule ProcessTypes.Frontend do
  @moduledoc """
  From source text to the core syntax that `ProcessTypes.Checker` types
  (GRAMMAR.md, §§2–4 and §7).

  Expressions:

      {:var, meta, x}
      {:atom, meta, a} | {:int, meta, n}
      {:tuple, meta, [e]}
      {:self, meta}
      {:arith, meta, op, e, e} | {:neg, meta, e} | {:cmp, meta, op, e, e}
      {:call, meta, {:local, f} | {:remote, module, f}, [e]}
      {:apply, meta, e, [e]}                      closure call e.(...)
      {:fn, meta, annotation | nil, [clause]}
      {:case, meta, e, [clause]}
      {:receive, meta, [clause]}
      {:send, meta, e, e}
      {:spawn, meta, interface, {:body, block} | {:expr, e}}
      {:block, meta, block}

  A block is a list of statements `{:expr, e}` and `{:match, meta, p, e}`; a clause is
  `{meta, [p], block}`; an annotation or interface is `{source_type, line}`. Patterns:

      {:pvar, meta, x} | {:pwild, meta} | {:patom, meta, a} | {:pint, meta, n}
      {:ptuple, meta, [p]} | {:pand, meta, p, p} | {:ptest, meta, type}

  where the type of `:ptest` is a Descr type. `not`, `and`, `or` and `if` are
  translated into `case`, and guards into intersection patterns.
  """

  alias ProcessTypes.{Annotations, Diagnostic, Types}

  defmodule Program do
    @moduledoc """
    A parsed program: its modules (in order), its functions by `{module, name, arity}`,
    its type definitions by `{module | nil, name}`, the statements of the main process,
    and the declared interface of the main process.
    """
    defstruct modules: [], funs: %{}, types: %{}, main: [], self_interface: nil
  end

  defmodule Fun do
    @moduledoc "A named function: its clauses share one annotation."
    defstruct [:module, :name, :arity, :private?, :line, :annotation, clauses: []]
  end

  @tests [:is_integer, :is_atom, :is_boolean, :is_tuple, :is_pid, :is_function]
  @arith [:+, :-, :*, :div, :rem]
  @comparisons [:==, :!=, :<, :<=, :>, :>=]
  @unsupported [
    :cond,
    :with,
    :for,
    :try,
    :unless,
    :&,
    :^,
    :@,
    :import,
    :alias,
    :require,
    :quote,
    :defmodule,
    :def,
    :defp,
    :|>,
    :<>,
    :++,
    :--,
    :/,
    :&&,
    :||,
    :!
  ]

  @doc "Returns `{program, diagnostics}`; the program is `nil` when the code does not parse."
  def parse(source) do
    {code, annotations, diagnostics} = Annotations.extract(source)

    case Code.string_to_quoted(code, columns: true, token_metadata: true) do
      {:ok, ast} ->
        {program, more} = program(ast, annotations)
        {program, diagnostics ++ more}

      {:error, {meta, message, token}} ->
        message = if is_binary(message), do: message <> token, else: inspect(message)
        {nil, diagnostics ++ [Diagnostic.error(meta[:line], "syntax error: " <> message)]}
    end
  end

  # Programs

  defp program(ast, annotations) do
    forms = block_forms(ast)
    {attach, diags} = attachments(ast, annotations)
    {types, self_interface, diags} = declarations(annotations, forms, diags)
    cx = %{attach: attach, module: nil}

    {program, diags} =
      Enum.reduce(forms, {%Program{types: types, self_interface: self_interface}, diags}, fn
        {:defmodule, _, _} = form, {program, diags} ->
          module(form, cx, program, diags)

        form, {program, diags} ->
          case guarded(fn -> stmt(form, cx) end) do
            {:ok, stmt} -> {%{program | main: program.main ++ [stmt]}, diags}
            {:error, diag} -> {program, diags ++ [diag]}
          end
      end)

    {program, diags}
  end

  defp block_forms({:__block__, _, forms}), do: forms
  defp block_forms(nil), do: []
  defp block_forms(form), do: [form]

  # Type definitions and the interface of the main process, scoped by the module
  # whose lines contain them.
  defp declarations(annotations, forms, diags) do
    modules =
      for {:defmodule, meta, [{:__aliases__, _, parts} | _]} <- forms,
          do: {Module.concat(parts), meta[:line], get_in(meta, [:end, :line]) || meta[:line]}

    scope = fn line ->
      Enum.find_value(modules, fn {module, first, last} ->
        if line >= first and line <= last, do: module
      end)
    end

    Enum.reduce(annotations, {%{}, nil, diags}, fn
      %{kind: :type, name: name, type: type, line: line}, {types, self, diags} ->
        key = {scope.(line), name}

        if Map.has_key?(types, key),
          do: {types, self, diags ++ [Diagnostic.error(line, "type #{name} is defined twice")]},
          else: {Map.put(types, key, {type, line}), self, diags}

      %{kind: :self_interface, type: type, line: line}, {types, self, diags} ->
        cond do
          scope.(line) != nil ->
            {types, self,
             diags ++ [Diagnostic.error(line, "$self_interface belongs to the top level")]}

          self != nil ->
            {types, self, diags ++ [Diagnostic.error(line, "$self_interface is declared twice")]}

          true ->
            {types, {type, line}, diags}
        end

      _, acc ->
        acc
    end)
  end

  # Which def, fn or spawn each annotation attaches to (GRAMMAR.md, §1).
  defp attachments(ast, annotations) do
    {_, pos} =
      Macro.prewalk(ast, %{defs: MapSet.new(), fns: [], spawns: []}, fn
        {kind, meta, [_ | _]} = node, acc when kind in [:def, :defp] ->
          {node, %{acc | defs: MapSet.put(acc.defs, meta[:line])}}

        {:fn, meta, _} = node, acc ->
          {node, %{acc | fns: [{meta[:line], meta[:column]} | acc.fns]}}

        {:spawn, meta, [_]} = node, acc ->
          {node, %{acc | spawns: [{meta[:line], meta[:column]} | acc.spawns]}}

        node, acc ->
          {node, acc}
      end)

    first_on = fn positions, line ->
      positions |> Enum.filter(&(elem(&1, 0) == line)) |> Enum.min_by(&elem(&1, 1), fn -> nil end)
    end

    Enum.reduce(annotations, {%{}, []}, fn ann, {attach, diags} ->
      key =
        case ann.kind do
          :fun ->
            cond do
              ann.target in pos.defs -> {:def, ann.target}
              position = first_on.(pos.fns, ann.target) -> {:fn, position}
              true -> {:error, "this annotation is followed by no def or fn"}
            end

          :interface ->
            if position = first_on.(pos.spawns, ann.target),
              do: {:spawn, position},
              else: {:error, "this $interface is followed by no spawn"}

          _ ->
            nil
        end

      case key do
        nil ->
          {attach, diags}

        {:error, message} ->
          {attach, diags ++ [Diagnostic.error(ann.line, message)]}

        key when is_map_key(attach, key) ->
          {attach, diags ++ [Diagnostic.error(ann.line, "a second annotation for the same code")]}

        key ->
          {Map.put(attach, key, {ann.type, ann.line}), diags}
      end
    end)
  end

  # Modules and functions

  defp module({:defmodule, _meta, [{:__aliases__, _, parts}, [do: body]]}, cx, program, diags) do
    name = Module.concat(parts)
    cx = %{cx | module: name}

    {groups, diags} =
      body
      |> block_forms()
      |> Enum.reduce({[], diags}, fn form, {groups, diags} ->
        case guarded(fn -> def_clause(form, cx) end) do
          {:ok, clause} -> group(clause, groups, diags)
          {:error, diag} -> {groups, diags ++ [diag]}
        end
      end)

    funs =
      for {kind, fname, arity, line, annotation, clauses} <- Enum.reverse(groups), into: %{} do
        {{name, fname, arity},
         %Fun{
           module: name,
           name: fname,
           arity: arity,
           private?: kind == :defp,
           line: line,
           annotation: annotation,
           clauses: Enum.reverse(clauses)
         }}
      end

    {%{program | modules: program.modules ++ [name], funs: Map.merge(program.funs, funs)}, diags}
  end

  defp module({:defmodule, meta, _}, _cx, program, diags),
    do: {program, diags ++ [Diagnostic.error(meta[:line], "unsupported form of defmodule")]}

  # Consecutive clauses of the same function form one group.
  defp group({kind, name, arity, line, annotation, clause}, groups, diags) do
    case groups do
      [{^kind, ^name, ^arity, first, ann, clauses} | rest] ->
        diags =
          if annotation,
            do:
              diags ++
                [
                  Diagnostic.error(
                    line,
                    "the annotation of #{name}/#{arity} must precede its first clause"
                  )
                ],
            else: diags

        {[{kind, name, arity, first, ann, [clause | clauses]} | rest], diags}

      _ ->
        cond do
          Enum.any?(groups, fn {_, n, a, _, _, _} -> {n, a} == {name, arity} end) ->
            {groups,
             diags ++
               [Diagnostic.error(line, "the clauses of #{name}/#{arity} must be consecutive")]}

          annotation == nil ->
            # Kept without annotation, so that the error is reported once; the
            # checker does not check it, and its calls have type none().
            {[{kind, name, arity, line, nil, [clause]} | groups],
             diags ++
               [
                 Diagnostic.error(
                   line,
                   "#{name}/#{arity} needs a $ annotation on the line before"
                 )
               ]}

          true ->
            {[{kind, name, arity, line, annotation, [clause]} | groups], diags}
        end
    end
  end

  defp def_clause({kind, meta, [head, body]}, cx) when kind in [:def, :defp] do
    {call, guard} =
      case head do
        {:when, _, [call, guard]} -> {call, guard}
        call -> {call, nil}
      end

    {name, args} =
      case call do
        {name, _, args} when is_atom(name) and is_list(args) -> {name, args}
        {name, _, context} when is_atom(name) and is_atom(context) -> {name, []}
        _ -> fail(meta, "unsupported function head")
      end

    body =
      case body do
        [do: body] -> body
        _ -> fail(meta, "a function body is written do ... end or , do: ...")
      end

    patterns = args |> Enum.map(&pattern/1) |> fold_guard(guard, meta)
    distinct!(patterns, meta)
    line = meta[:line]
    {kind, name, length(args), line, cx.attach[{:def, line}], {meta, patterns, block(body, cx)}}
  end

  defp def_clause(form, _cx),
    do: fail(meta_of(form), "a module contains only def, defp and $ lines")

  # Statements and expressions

  defp block({:__block__, meta, []}, _cx), do: [{:expr, {:atom, meta, nil}}]
  defp block({:__block__, _, forms}, cx), do: Enum.map(forms, &stmt(&1, cx))
  defp block(form, cx), do: [stmt(form, cx)]

  defp stmt({:=, meta, [p, e]}, cx) do
    p = pattern(p)
    distinct!([p], meta)
    {:match, meta, p, expr(e, cx)}
  end

  defp stmt({:defmodule, meta, _}, _cx), do: fail(meta, "modules are not nested")

  defp stmt({kind, meta, _}, _cx) when kind in [:def, :defp],
    do: fail(meta, "#{kind} outside a module")

  defp stmt(e, cx), do: {:expr, expr(e, cx)}

  defp expr(n, _cx) when is_integer(n), do: {:int, [], n}
  defp expr(a, _cx) when is_atom(a), do: {:atom, [], a}
  defp expr({:-, meta, [n]}, _cx) when is_integer(n), do: {:int, meta, -n}
  defp expr({a, b}, cx), do: {:tuple, [], [expr(a, cx), expr(b, cx)]}
  defp expr({:{}, meta, es}, cx), do: {:tuple, meta, Enum.map(es, &expr(&1, cx))}
  defp expr({:__block__, meta, _} = b, cx), do: {:block, meta, block(b, cx)}
  defp expr({:self, meta, []}, _cx), do: {:self, meta}

  defp expr({op, meta, [a, b]}, cx) when op in @arith,
    do: {:arith, meta, op, expr(a, cx), expr(b, cx)}

  defp expr({:-, meta, [a]}, cx), do: {:neg, meta, expr(a, cx)}

  defp expr({op, meta, [a, b]}, cx) when op in @comparisons,
    do: {:cmp, meta, op, expr(a, cx), expr(b, cx)}

  defp expr({:not, meta, [a]}, cx),
    do: bool_case(meta, expr(a, cx), {:atom, meta, false}, {:atom, meta, true})

  defp expr({:and, meta, [a, b]}, cx),
    do: bool_case(meta, expr(a, cx), expr(b, cx), {:atom, meta, false})

  defp expr({:or, meta, [a, b]}, cx),
    do: bool_case(meta, expr(a, cx), {:atom, meta, true}, expr(b, cx))

  defp expr({:if, meta, [c, kw]}, cx) when is_list(kw) do
    then_block = block(Keyword.fetch!(kw, :do), cx)
    else_block = block(Keyword.get(kw, :else, nil), cx)
    falsy = {:ptest, meta, Types.atom([nil, false])}

    {:case, meta, expr(c, cx),
     [{meta, [falsy], else_block}, {meta, [{:pwild, meta}], then_block}]}
  end

  defp expr({:case, meta, [e, [do: clauses]]}, cx),
    do: {:case, meta, expr(e, cx), Enum.map(clauses, &clause(&1, cx))}

  defp expr({:receive, meta, [[do: clauses]]}, cx),
    do: {:receive, meta, Enum.map(clauses, &clause(&1, cx))}

  defp expr({:receive, meta, _}, _cx), do: fail(meta, "receive ... after is not supported")

  defp expr({:fn, meta, clauses}, cx) do
    annotation = cx.attach[{:fn, {meta[:line], meta[:column]}}]
    {:fn, meta, annotation, Enum.map(clauses, &fn_clause(&1, cx))}
  end

  defp expr({:send, meta, [a, b]}, cx), do: {:send, meta, expr(a, cx), expr(b, cx)}

  defp expr({:spawn, meta, [e]}, cx) do
    interface =
      cx.attach[{:spawn, {meta[:line], meta[:column]}}] ||
        fail(meta, "spawn needs a $interface annotation on the line before")

    # An unannotated fn -> b end is spawned as its body b (Section 5 of the paper).
    target =
      case e do
        {:fn, fmeta, [{:->, _, [[], body]}]} ->
          if Map.has_key?(cx.attach, {:fn, {fmeta[:line], fmeta[:column]}}),
            do: {:expr, expr(e, cx)},
            else: {:body, block(body, cx)}

        e ->
          {:expr, expr(e, cx)}
      end

    {:spawn, meta, interface, target}
  end

  defp expr({{:., _, [{:__aliases__, _, parts}, f]}, meta, args}, cx)
       when is_atom(f) and is_list(args),
       do: {:call, meta, {:remote, Module.concat(parts), f}, Enum.map(args, &expr(&1, cx))}

  defp expr({{:., _, [e]}, meta, args}, cx) when is_list(args),
    do: {:apply, meta, expr(e, cx), Enum.map(args, &expr(&1, cx))}

  defp expr({:_, meta, context}, _cx) when is_atom(context),
    do: fail(meta, "_ is not an expression")

  defp expr({x, meta, context}, _cx) when is_atom(x) and is_atom(context), do: {:var, meta, x}

  defp expr({name, meta, _}, _cx) when name in @unsupported,
    do: fail(meta, "#{name} is not supported")

  defp expr({name, meta, args}, cx) when is_atom(name) and is_list(args),
    do: {:call, meta, {:local, name}, Enum.map(args, &expr(&1, cx))}

  defp expr(other, _cx),
    do: fail(meta_of(other), "unsupported expression: #{Macro.to_string(other)}")

  defp bool_case(meta, scrutinee, if_true, if_false) do
    {:case, meta, scrutinee,
     [
       {meta, [{:patom, meta, true}], [{:expr, if_true}]},
       {meta, [{:patom, meta, false}], [{:expr, if_false}]}
     ]}
  end

  # Clauses

  defp clause({:->, meta, [[head], body]}, cx) do
    {p, guard} =
      case head do
        {:when, _, [p, guard]} -> {p, guard}
        p -> {p, nil}
      end

    patterns = fold_guard([pattern(p)], guard, meta)
    distinct!(patterns, meta)
    {meta, patterns, block(body, cx)}
  end

  defp clause({:->, meta, _}, _cx),
    do: fail(meta, "a case or receive clause has exactly one pattern")

  defp fn_clause({:->, meta, [params, body]}, cx) do
    {params, guard} =
      case params do
        [{:when, _, args}] -> {Enum.drop(args, -1), List.last(args)}
        params -> {params, nil}
      end

    patterns = params |> Enum.map(&pattern/1) |> fold_guard(guard, meta)
    distinct!(patterns, meta)
    {meta, patterns, block(body, cx)}
  end

  # Patterns and guards

  defp pattern(n) when is_integer(n), do: {:pint, [], n}
  defp pattern({:-, meta, [n]}) when is_integer(n), do: {:pint, meta, -n}
  defp pattern(a) when is_atom(a), do: {:patom, [], a}
  defp pattern({a, b}), do: {:ptuple, [], [pattern(a), pattern(b)]}
  defp pattern({:{}, meta, ps}), do: {:ptuple, meta, Enum.map(ps, &pattern/1)}
  defp pattern({:=, meta, [p1, p2]}), do: {:pand, meta, pattern(p1), pattern(p2)}
  defp pattern({:_, meta, context}) when is_atom(context), do: {:pwild, meta}
  defp pattern({x, meta, context}) when is_atom(x) and is_atom(context), do: {:pvar, meta, x}
  defp pattern({:^, meta, _}), do: fail(meta, "the pin operator is not supported")
  defp pattern(other), do: fail(meta_of(other), "unsupported pattern: #{Macro.to_string(other)}")

  defp fold_guard(patterns, nil, _meta), do: patterns

  defp fold_guard(patterns, guard, meta) do
    Enum.reduce(guard(guard), patterns, fn {x, test}, patterns ->
      {patterns, found?} = Enum.map_reduce(patterns, false, &refine(&1, x, test, &2))

      if found?,
        do: patterns,
        else: fail(meta, "the guard tests #{x}, which the patterns do not bind")
    end)
  end

  defp refine({:pvar, meta, x} = p, x, test, _),
    do: {{:pand, meta, p, {:ptest, meta, test}}, true}

  defp refine({:ptuple, meta, ps}, x, test, found?) do
    {ps, found?} = Enum.map_reduce(ps, found?, &refine(&1, x, test, &2))
    {{:ptuple, meta, ps}, found?}
  end

  defp refine({:pand, meta, p1, p2}, x, test, found?) do
    {p1, found?} = refine(p1, x, test, found?)
    {p2, found?} = refine(p2, x, test, found?)
    {{:pand, meta, p1, p2}, found?}
  end

  defp refine(p, _x, _test, found?), do: {p, found?}

  # A guard denotes a test type for each variable it tests (GRAMMAR.md, §4).
  defp guard({test, _, [{x, _, context}]})
       when test in @tests and is_atom(x) and is_atom(context),
       do: %{x => test_type(test)}

  defp guard({:and, _, [g1, g2]}),
    do: Map.merge(guard(g1), guard(g2), fn _, t1, t2 -> Types.intersection(t1, t2) end)

  defp guard({:or, meta, [g1, g2]}) do
    case {Map.to_list(guard(g1)), Map.to_list(guard(g2))} do
      {[{x, t1}], [{x, t2}]} -> %{x => Types.union(t1, t2)}
      _ -> fail(meta, "or combines tests of one variable only")
    end
  end

  defp guard({:not, meta, [g]}) do
    case Map.to_list(guard(g)) do
      [{x, t}] -> %{x => Types.negation(t)}
      _ -> fail(meta, "not applies to tests of one variable only")
    end
  end

  defp guard(other),
    do: fail(meta_of(other), "unsupported guard: only type tests of variables are allowed")

  defp test_type(:is_integer), do: Types.integer()
  defp test_type(:is_atom), do: Types.atom()
  defp test_type(:is_boolean), do: Types.boolean()
  defp test_type(:is_tuple), do: Types.tuple()
  defp test_type(:is_pid), do: Types.pid()
  defp test_type(:is_function), do: Types.fun()

  defp distinct!(patterns, meta) do
    vars = Enum.flat_map(patterns, &vars/1)

    case vars -- Enum.uniq(vars) do
      [] ->
        :ok

      [x | _] ->
        fail(
          meta,
          "#{x} occurs twice in the patterns of a clause (there is no implicit equality test)"
        )
    end
  end

  defp vars({:pvar, _, x}), do: [x]
  defp vars({:ptuple, _, ps}), do: Enum.flat_map(ps, &vars/1)
  defp vars({:pand, _, p1, p2}), do: vars(p1) ++ vars(p2)
  defp vars(_), do: []

  # Errors

  defp fail(meta, message), do: throw({:frontend, meta[:line], message})

  defp guarded(fun) do
    {:ok, fun.()}
  catch
    {:frontend, line, message} -> {:error, Diagnostic.error(line, message)}
  end

  defp meta_of({_, meta, _}) when is_list(meta), do: meta
  defp meta_of(_), do: []
end
