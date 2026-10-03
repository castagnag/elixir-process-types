defmodule ProcessTypes.TypeGraph do
  @moduledoc """
  The meaning of annotation types, recursive ones included.

  A source type (`ProcessTypes.TypeSyntax`) and the definitions it reaches denote a
  regular tree, represented here by a finite graph: one node per subterm, a type name
  being an edge to the root of its body, so that a recursive definition is a cycle.
  Types are contractive (Section 3 of the paper): every cycle passes through a type
  constructor, that is, a tuple, a pid or an arrow; a cycle through `or`, `and` and
  `not` only is rejected.

  The graph is compiled into Descr one strongly connected component at a time, the
  components below first. A node on no cycle is an ordinary type. The nodes of a cycle
  are the equations of one recursive system (`ProcessTypes.Types.recursive/1`), each
  holding a single constructor or connective applied to the other nodes. Since Descr
  evaluates connectives eagerly, this normal form never applies a connective to a node
  of the system inside an argument of a constructor; in particular the pointed domain
  `s or ℧` of an arrow whose argument is in the system is an equation of its own.

  Printed recursive types, `{:rec, x, t}` with `{:recvar, x}` for the occurrences of x
  in t, are read back in the same way, x being a definition local to t.
  """

  import Kernel, except: [to_string: 1]
  alias ProcessTypes.{TypeSyntax, Types}

  @connectives [:or, :and, :not]

  @doc """
  The Descr type denoted by `t`. Type names are resolved in `defs`, which maps
  `{module | nil, name}` to `{source_type, line}`; a bare name in the scope of a module
  is first looked up in that module.
  """
  def to_descr(t, defs, scope) do
    {g, root} = build(t, defs, scope)
    {:ok, g |> compile([root], %{}) |> Map.fetch!(root)}
  catch
    {:type_syntax, message} -> {:error, message}
  end

  @doc """
  The arrows of a function annotation `L` (GRAMMAR.md, §5.1): a list of maps with the
  arity, the domain `s`, the decorations `o` and `i`, the codomain `t`, and the source.
  """
  def arrows(t, defs, scope) do
    {g, root} = build(t, defs, scope)
    tops = conjuncts(g, root)
    descrs = compile(g, [root], %{})
    {:ok, Enum.map(tops, &arrow_parts(g, descrs, &1, nil))}
  catch
    {:type_syntax, message} -> {:error, message}
  end

  @doc """
  Like `to_descr/3`, but the arrows written without decorations get type variables, as
  decorate(·) does (Definition `def:decorate` of the paper): a fresh pair for each
  class of equal arrow annotations, equality being that of the regular trees (names
  are transparent). Returns the type and the variables minted, as `{variable, role}`
  with role `:o` or `:i`; `prefix` names them.
  """
  def decorate(t, defs, scope, prefix) do
    {g, root} = build(t, defs, scope)
    {pairs, minted} = class_pairs(g, [root], prefix, MapSet.new())
    {:ok, g |> compile([root], pairs) |> Map.fetch!(root), minted}
  catch
    {:type_syntax, message} -> {:error, message}
  end

  @doc """
  Like `arrows/3`, but decorating as `decorate/4` does, except that each top-level
  arrow written without decorations gets a fresh pair of its own (rule i-abs): its
  domain and codomain are decorated with the classes of the whole annotation.
  """
  def decorate_arrows(t, defs, scope, prefix) do
    {g, root} = build(t, defs, scope)
    tops = conjuncts(g, root)
    # A top-level arrow that occurs nowhere else needs no pair of its class.
    spine = spine(g, root)

    inner =
      for id <- reachable(g, [root]),
          not MapSet.member?(spine, id),
          child <- elem(g.nodes[id], 1),
          into: MapSet.new(),
          do: child

    alone = tops |> Enum.reject(&MapSet.member?(inner, &1)) |> MapSet.new()
    {pairs, minted} = class_pairs(g, [root], prefix, alone)
    descrs = compile(g, [root], pairs)

    {arrows, minted} =
      tops
      |> Enum.with_index(1)
      |> Enum.map_reduce(minted, fn {id, j}, minted ->
        suffix = if length(tops) == 1, do: "", else: "_#{j}"

        case g.nodes[id] do
          {{:arrow, _, false}, _} ->
            o = Types.var(:"o_#{prefix}#{suffix}")
            i = Types.var(:"i_#{prefix}#{suffix}")
            {arrow_parts(g, descrs, id, {o, i}), minted ++ [{o, :o}, {i, :i}]}

          _ ->
            {arrow_parts(g, descrs, id, nil), minted}
        end
      end)

    {:ok, arrows, minted}
  catch
    {:type_syntax, message} -> {:error, message}
  end

  # Building the graph. A name, and a printed rec, is first an :alias node, which
  # compress/2 replaces by the root of its body.

  defp build(t, defs, scope) do
    g = %{nodes: %{}, sources: %{}, names: %{}, memo: %{}, next: 0, defs: defs}
    {root, g} = node(t, scope, %{}, g)
    {g, root} = compress(g, root)
    contractive!(g, root)
    {g, root}
  end

  defp node({:name, _, _} = name, scope, _recs, g) do
    {key, body, body_scope} = resolve(name, g.defs, scope)

    case g.memo do
      %{^key => id} ->
        {id, g}

      %{} ->
        {id, g} = new(g, :alias, [], name)
        g = %{g | memo: Map.put(g.memo, key, id), names: Map.put(g.names, id, key)}
        # The local definitions of a printed type do not reach into a type definition.
        {child, g} = node(body, body_scope, %{}, g)
        {id, put_in(g.nodes[id], {:alias, [child]})}
    end
  end

  defp node({:rec, x, body} = t, scope, recs, g) do
    {id, g} = new(g, :alias, [], t)
    g = %{g | names: Map.put(g.names, id, {nil, x})}
    {child, g} = node(body, scope, Map.put(recs, x, id), g)
    {id, put_in(g.nodes[id], {:alias, [child]})}
  end

  defp node({:recvar, x}, _scope, recs, g) do
    case recs do
      %{^x => id} -> {id, g}
      %{} -> bad("unbound recursion variable #{x}")
    end
  end

  defp node({:tuple, ts} = t, scope, recs, g) do
    {ids, g} = nodes(ts, scope, recs, g)
    new(g, {:tuple, length(ts)}, ids, t)
  end

  defp node({:pid, :none} = t, _scope, _recs, g), do: new(g, {:leaf, t}, [], t)

  defp node({:pid, u} = t, scope, recs, g) do
    {id, g} = node(u, scope, recs, g)
    new(g, :pid, [id], t)
  end

  defp node({:arrow, args, ret, decorations} = t, scope, recs, g) do
    written = if decorations, do: Tuple.to_list(decorations), else: []
    {ids, g} = nodes(args ++ [ret | written], scope, recs, g)
    new(g, {:arrow, length(args), decorations != nil}, ids, t)
  end

  defp node({op, a, b} = t, scope, recs, g) when op in [:or, :and] do
    {ids, g} = nodes([a, b], scope, recs, g)
    new(g, op, ids, t)
  end

  defp node({:not, a} = t, scope, recs, g) do
    {id, g} = node(a, scope, recs, g)
    new(g, :not, [id], t)
  end

  defp node({:atom, _} = t, _scope, _recs, g), do: new(g, {:leaf, t}, [], t)

  defp node(t, _scope, _recs, g)
       when t in [:integer, :atom, :boolean, :tuple, :term, :none, :fun],
       do: new(g, {:leaf, t}, [], t)

  defp node({:raw, _}, _scope, _recs, _g), do: bad("this type has no source form")
  defp node({:var, x}, _scope, _recs, _g), do: bad("the type variable #{x} has no source form")

  defp nodes(ts, scope, recs, g) do
    {ids, g} = Enum.map_reduce(ts, g, fn t, g -> node(t, scope, recs, g) end)
    {ids, g}
  end

  defp new(g, label, children, source) do
    id = g.next

    g = %{
      g
      | nodes: Map.put(g.nodes, id, {label, children}),
        sources: Map.put(g.sources, id, source),
        next: id + 1
    }

    {id, g}
  end

  defp resolve({:name, module, name}, defs, scope) do
    key =
      cond do
        module != nil and Map.has_key?(defs, {module, name}) -> {module, name}
        module != nil -> bad("unknown type #{inspect(module)}.#{name}")
        scope != nil and Map.has_key?(defs, {scope, name}) -> {scope, name}
        Map.has_key?(defs, {nil, name}) -> {nil, name}
        true -> bad("unknown type #{name}")
      end

    {body, _line} = Map.fetch!(defs, key)
    {key, body, elem(key, 0)}
  end

  # Every alias is replaced by the root of its body; the name moves to that root. A
  # cycle of aliases (a = b, b = a) has no root: it is not contractive.
  defp compress(g, root) do
    aliases = for {id, {:alias, [_]}} <- g.nodes, into: %{}, do: {id, target(g, id, [])}
    via = &Map.get(aliases, &1, &1)

    nodes =
      for {id, {label, children}} <- g.nodes,
          label != :alias,
          into: %{},
          do: {id, {label, Enum.map(children, via)}}

    # The name of a node is the first of the names whose root it is, in build order.
    names =
      g.names
      |> Enum.sort()
      |> Enum.reduce(%{}, fn {id, name}, names -> Map.put_new(names, via.(id), name) end)

    {%{g | nodes: nodes, names: names}, via.(root)}
  end

  defp target(g, id, path) do
    case g.nodes[id] do
      {:alias, [child]} ->
        if id in path,
          do: not_contractive(g, [id | Enum.reverse(Enum.take_while(path, &(&1 != id)))]),
          else: target(g, child, [id | path])

      _ ->
        id
    end
  end

  # A cycle whose nodes are all connectives contains no constructor.
  defp contractive!(g, root) do
    reachable(g, [root])
    |> Enum.filter(&(label(g, &1) in @connectives))
    |> Enum.reduce(%{}, fn id, colors -> visit(g, id, [], colors) end)

    :ok
  end

  defp visit(g, id, path, colors) do
    case colors[id] do
      :done ->
        colors

      :active ->
        # path holds the ancestors, the parent first
        not_contractive(g, [id | Enum.reverse(Enum.take_while(path, &(&1 != id)))])

      nil ->
        colors = Map.put(colors, id, :active)

        colors =
          g.nodes[id]
          |> elem(1)
          |> Enum.filter(&(label(g, &1) in @connectives))
          |> Enum.reduce(colors, fn child, colors -> visit(g, child, [id | path], colors) end)

        Map.put(colors, id, :done)
    end
  end

  # The cycle is given without repeating its first node.
  defp not_contractive(g, cycle) do
    names = cycle |> Enum.map(&g.names[&1]) |> Enum.reject(&is_nil/1) |> Enum.dedup()

    case names do
      [] ->
        bad("this type is not contractive: it is recursive through or, and and not only")

      [name | _] ->
        path = Enum.map_join(names ++ [name], " -> ", &key_to_string/1)

        bad(
          "the definition of #{key_to_string(name)} is not contractive: the cycle #{path} " <>
            "passes through no tuple, pid or arrow"
        )
    end
  end

  defp key_to_string({nil, name}), do: Atom.to_string(name)
  defp key_to_string({module, name}), do: "#{inspect(module)}.#{name}"

  defp label(g, id), do: elem(g.nodes[id], 0)

  defp reachable(g, roots), do: reachable(g, roots, MapSet.new()) |> MapSet.to_list()

  defp reachable(_g, [], seen), do: seen

  defp reachable(g, [id | rest], seen) do
    if MapSet.member?(seen, id),
      do: reachable(g, rest, seen),
      else: reachable(g, elem(g.nodes[id], 1) ++ rest, MapSet.put(seen, id))
  end

  # The intersections above the top-level arrows of a function annotation.
  defp spine(g, id) do
    case g.nodes[id] do
      {:and, [a, b]} -> MapSet.new([id]) |> MapSet.union(spine(g, a)) |> MapSet.union(spine(g, b))
      _ -> MapSet.new()
    end
  end

  # The top-level arrows of a function annotation: the conjuncts of its intersections.
  defp conjuncts(g, id) do
    case g.nodes[id] do
      {:and, [a, b]} ->
        conjuncts(g, a) ++ conjuncts(g, b)

      {{:arrow, _, _}, _} ->
        [id]

      _ ->
        bad(
          "a function annotation is an intersection of arrows, not " <>
            TypeSyntax.to_string(g.sources[id])
        )
    end
  end

  defp arrow_parts(g, descrs, id, pair) do
    {{:arrow, n, written?}, children} = g.nodes[id]
    {args, [ret | written]} = Enum.split(children, n)
    {o, i} = decorations(written?, Enum.map(written, &descrs[&1]), pair)

    %{
      arity: n,
      s: domain(Enum.map(args, &descrs[&1])),
      o: o,
      i: i,
      t: descrs[ret],
      source: g.sources[id]
    }
  end

  # Written decorations are kept; the others are the pair given, or the least ones,
  # @[none(), term()].
  defp decorations(true, [o, i], _pair), do: {o, i}
  defp decorations(false, [], nil), do: {Types.none(), Types.term()}
  defp decorations(false, [], pair), do: pair

  defp domain([s]), do: s
  defp domain(args), do: Types.tuple(args)

  # Compilation

  # `pairs` maps the arrows written without decorations to their pair; the others have
  # the least decorations.
  defp compile(g, roots, pairs) do
    g
    |> components(roots)
    |> Enum.reduce(%{}, fn component, descrs ->
      case component do
        [id] ->
          if id in elem(g.nodes[id], 1),
            do: system(g, [id], descrs, pairs),
            else: one(g, id, descrs, pairs)

        ids ->
          system(g, ids, descrs, pairs)
      end
    end)
  end

  defp one(g, id, descrs, pairs) do
    {label, children} = g.nodes[id]
    Map.put(descrs, id, eager(label, Enum.map(children, &descrs[&1]), pairs[id]))
  end

  defp eager({:leaf, t}, [], _pair), do: leaf(t)
  defp eager({:tuple, _}, ts, _pair), do: Types.tuple(ts)
  defp eager(:pid, [t], _pair), do: Types.pid(t)
  defp eager(:or, [a, b], _pair), do: Types.union(a, b)
  defp eager(:and, [a, b], _pair), do: Types.intersection(a, b)
  defp eager(:not, [a], _pair), do: Types.negation(a)

  defp eager({:arrow, n, written?}, children, pair) do
    {args, [ret | written]} = Enum.split(children, n)
    {o, i} = decorations(written?, written, pair)
    Types.arrow(domain(args), o, i, ret)
  end

  defp leaf({:atom, a}), do: Types.atom([a])
  defp leaf({:pid, :none}), do: Types.pid()
  defp leaf(:integer), do: Types.integer()
  defp leaf(:atom), do: Types.atom()
  defp leaf(:boolean), do: Types.boolean()
  defp leaf(:tuple), do: Types.tuple()
  defp leaf(:term), do: Types.term()
  defp leaf(:none), do: Types.none()
  defp leaf(:fun), do: Types.fun()

  # The nodes of a cycle: one equation each, plus one for the pointed domain of every
  # unary arrow whose argument is in the cycle.
  defp system(g, ids, descrs, pairs) do
    members = MapSet.new(ids)
    keys = equation_keys(g, ids)

    pointed =
      for id <- ids,
          {{:arrow, 1, _}, [arg | _]} <- [g.nodes[id]],
          MapSet.member?(members, arg),
          uniq: true,
          do: arg

    equations =
      Map.new(ids, fn id ->
        {label, children} = g.nodes[id]

        {keys[id],
         fn recur ->
           ref = fn child ->
             if MapSet.member?(members, child), do: recur.(keys[child]), else: descrs[child]
           end

           pointed_ref = fn arg -> recur.({:pointed, keys[arg]}) end
           lazy(label, children, ref, pointed_ref, members, pairs[id])
         end}
      end)

    equations =
      Enum.reduce(pointed, equations, fn arg, equations ->
        Map.put(equations, {:pointed, keys[arg]}, fn recur ->
          Types.bare_pointed(recur.(keys[arg]))
        end)
      end)

    nodes = Types.recursive(equations)
    Enum.reduce(ids, descrs, fn id, descrs -> Map.put(descrs, id, nodes[keys[id]]) end)
  end

  defp lazy({:tuple, _}, children, ref, _pointed_ref, _members, _pair),
    do: Types.tuple(Enum.map(children, ref))

  defp lazy(:pid, [t], ref, _pointed_ref, _members, _pair), do: Types.pid(ref.(t))
  defp lazy(:or, [a, b], ref, _, _, _), do: Types.bare_union(ref.(a), ref.(b))
  defp lazy(:and, [a, b], ref, _, _, _), do: Types.bare_intersection(ref.(a), ref.(b))
  defp lazy(:not, [a], ref, _, _, _), do: Types.bare_negation(ref.(a))

  defp lazy({:arrow, n, written?}, children, ref, pointed_ref, members, pair) do
    {args, [ret | written]} = Enum.split(children, n)
    {o, i} = decorations(written?, Enum.map(written, ref), pair)

    ps =
      case args do
        [arg] ->
          if MapSet.member?(members, arg),
            do: pointed_ref.(arg),
            else: Types.pointed(ref.(arg))

        args ->
          Types.pointed(Types.tuple(Enum.map(args, ref)))
      end

    Types.pointed_arrow(ps, o, i, ref.(ret))
  end

  # Decoration classes. Two nodes denote the same regular tree if they are bisimilar:
  # the coarsest partition of the nodes into blocks with the same label and children in
  # the same blocks, computed by refinement from the partition by labels (Moore). The
  # arrows written without decorations get one fresh pair per block.
  defp class_pairs(g, roots, prefix, excluded) do
    ids = reachable(g, roots)
    blocks = refine(g, ids, number(Map.new(ids, &{&1, label(g, &1)})))

    ids
    |> Enum.filter(&match?({:arrow, _, false}, label(g, &1)))
    |> Enum.reject(&MapSet.member?(excluded, &1))
    |> Enum.group_by(&blocks[&1])
    |> Enum.sort_by(fn {_block, members} -> Enum.min(members) end)
    |> Enum.with_index(1)
    |> Enum.reduce({%{}, []}, fn {{_block, members}, k}, {pairs, minted} ->
      o = Types.var(:"o_#{prefix}_a#{k}")
      i = Types.var(:"i_#{prefix}_a#{k}")
      pairs = Enum.reduce(members, pairs, &Map.put(&2, &1, {o, i}))
      {pairs, minted ++ [{o, :o}, {i, :i}]}
    end)
  end

  defp refine(g, ids, blocks) do
    refined =
      number(
        Map.new(ids, fn id ->
          {label, children} = g.nodes[id]
          {id, {blocks[id], label, Enum.map(children, &blocks[&1])}}
        end)
      )

    if count(refined) == count(blocks), do: blocks, else: refine(g, ids, refined)
  end

  # Numbers the distinct keys of a map from nodes to keys.
  defp number(keys) do
    index = keys |> Map.values() |> Enum.uniq() |> Enum.with_index() |> Map.new()
    Map.new(keys, fn {id, key} -> {id, index[key]} end)
  end

  defp count(blocks), do: blocks |> Map.values() |> Enum.uniq() |> length()

  # Equation keys are atoms, which Descr prints as the names of recursive types: the
  # name of the type definition whose root the node is, or t<id>.
  defp equation_keys(g, ids) do
    {keys, _used} =
      Enum.reduce(Enum.sort(ids), {%{}, MapSet.new()}, fn id, {keys, used} ->
        base =
          case g.names[id] do
            {_module, name} -> Atom.to_string(name)
            nil -> "t#{id}"
          end

        key =
          Stream.iterate(1, &(&1 + 1))
          |> Stream.map(fn
            1 -> base
            k -> "#{base}_#{k}"
          end)
          |> Enum.find(&(not MapSet.member?(used, &1)))

        {Map.put(keys, id, String.to_atom(key)), MapSet.put(used, key)}
      end)

    keys
  end

  # Tarjan's algorithm: the strongly connected components reachable from the roots, each
  # after the components it reaches.
  defp components(g, roots) do
    state = %{index: %{}, low: %{}, stack: [], on: MapSet.new(), next: 0, out: []}

    roots
    |> Enum.reduce(state, fn root, state ->
      if Map.has_key?(state.index, root), do: state, else: strong(g, root, state)
    end)
    |> Map.fetch!(:out)
    |> Enum.reverse()
  end

  defp strong(g, v, state) do
    state = %{
      state
      | index: Map.put(state.index, v, state.next),
        low: Map.put(state.low, v, state.next),
        stack: [v | state.stack],
        on: MapSet.put(state.on, v),
        next: state.next + 1
    }

    state =
      g.nodes[v]
      |> elem(1)
      |> Enum.reduce(state, fn w, state ->
        cond do
          not Map.has_key?(state.index, w) ->
            state = strong(g, w, state)
            %{state | low: Map.update!(state.low, v, &min(&1, state.low[w]))}

          MapSet.member?(state.on, w) ->
            %{state | low: Map.update!(state.low, v, &min(&1, state.index[w]))}

          true ->
            state
        end
      end)

    if state.low[v] == state.index[v] do
      {component, [^v | stack]} = Enum.split_while(state.stack, &(&1 != v))
      component = [v | component]

      %{
        state
        | stack: stack,
          on: Enum.reduce(component, state.on, &MapSet.delete(&2, &1)),
          out: [component | state.out]
      }
    else
      state
    end
  end

  defp bad(message), do: throw({:type_syntax, message})
end
