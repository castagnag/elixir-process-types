defmodule ProcessTypes.Reconstruct do
  @moduledoc """
  The reconstruction of the interfaces of the `spawn`s that declare none (Section 9 of
  the paper, Definition `def:reconstruction`; GRAMMAR.md, §11).

  `run/5` receives the state of `ProcessTypes.Backend.Infer` after the generation step,
  which recorded the constraints with their kinds, the uses of rule i-receive and the
  unannotated `spawn`s (rule i-spawn-alt). For each of these, and for the main process
  when its interface is not declared, it derives the bound on the interface
  (`ProcessTypes.Reconstruct.Derive`), solves it in dependency order
  (`ProcessTypes.Reconstruct.Solve`), and runs the checking step: the pid variable of
  each `spawn` is replaced by its interface t, the constraints β ≤ t ≤ α of rule i-spawn
  take the place that they would have with a declared interface, and the constraints are
  solved as in inference mode (`ProcessTypes.Backend.Infer.finish_with/4`).

  The bounds are read in the normal forms that tallying gives to the constraints
  (`ProcessTypes.Reconstruct.Bounds`, `ProcessTypes.Reconstruct.Store`).
  """

  alias ProcessTypes.Backend.Infer
  alias ProcessTypes.{Diagnostic, Printer, Types}
  alias ProcessTypes.Reconstruct.{Derive, Solve, Store}

  @doc """
  Returns the state after the checking step, with the diagnostics of the `spawn`s whose
  interface cannot be reconstructed, and the interfaces as `%{line: line, type: t}`:
  `line` is `nil` for the main process, `t` is `nil` after a failure.
  """
  def run(st, program, sigs, reported, names) do
    spawns = for {:spawn_alt, info} <- Infer.events(st), do: info

    if spawns == [] do
      {Infer.finish_with(st, %{}, %{}, reported), []}
    else
      Store.with_cache(fn -> reconstruct(st, spawns, program, sigs, reported, names) end)
    end
  end

  defp reconstruct(st, spawns, program, sigs, reported, names) do
    world = world(st, spawns, program, sigs)
    derived = Map.new(spawns, &{&1.occurrence, Derive.derive(world, &1)})

    dependencies =
      Map.new(spawns, &{&1.occurrence, Solve.dependencies(world, &1, derived[&1.occurrence])})

    results = solve_all(spawns, world, derived, dependencies, %{})
    show = fn t -> Printer.to_string(t, Map.get(names, nil, [])) end

    pre = for s <- spawns, {:ok, t} <- [results[s.occurrence]], into: %{}, do: {s.pid, t}

    brackets =
      for s <- spawns, {:ok, t} <- [results[s.occurrence]], into: %{} do
        diagnostic = fn _inst ->
          Diagnostic.error(
            s.line,
            "#{subject(s)} does not keep to its reconstructed interface #{show.(t)}"
          )
        end

        {s.occurrence,
         [
           %{sub: s.o, sup: t, line: s.line, diagnostic: diagnostic},
           %{sub: t, sup: s.i, line: s.line, diagnostic: diagnostic}
         ]}
      end

    st = Infer.finish_with(st, pre, brackets, reported)

    failures =
      for s <- spawns, {:error, reason} <- [results[s.occurrence]] do
        Diagnostic.error(
          s.line,
          "the interface of #{subject(s, :lower)} cannot be reconstructed: " <>
            reason(reason, spawns) <> "; declare it with #{annotation(s)}"
        )
      end

    interfaces =
      spawns
      |> Enum.map(fn s ->
        case results[s.occurrence] do
          {:ok, t} -> %{line: s.line, type: t}
          _ -> %{line: s.line, type: nil}
        end
      end)
      |> Enum.sort_by(&{&1.line == nil, &1.line})

    {%{st | diags: Enum.reverse(failures) ++ st.diags}, interfaces}
  end

  defp subject(spawn, style \\ :upper)
  defp subject(%{occurrence: :main}, _style), do: "the main process"
  defp subject(_spawn, :upper), do: "spawn: the process"
  defp subject(_spawn, :lower), do: "this spawn"

  defp annotation(%{occurrence: :main}), do: "$self_interface"
  defp annotation(_spawn), do: "$interface"

  defp reason({:polarity, _v}, _spawns),
    do:
      "a branch of its receives relates two parts of a message, so that no interface is " <>
        "the most permissive (a type variable occurs with both polarities in its demands)"

  defp reason(:unguarded, _spawns), do: "what the process reads does not determine it"

  defp reason({:cycle, others}, spawns),
    do: "it depends on #{others(others, spawns)}, whose interface depends on it"

  defp reason({:failed, others}, spawns),
    do: "it depends on #{others(others, spawns)}, whose interface cannot be reconstructed"

  defp others(occurrences, spawns) do
    spawns
    |> Enum.filter(&(&1.occurrence in occurrences))
    |> Enum.map_join(" and ", fn
      %{occurrence: :main} -> "the main process"
      s -> "the spawn of line #{s.line}"
    end)
  end

  # The constraints of the program under θ_M, their store, and what the generation
  # recorded.
  defp world(st, spawns, program, sigs) do
    {pure, theta} = Solve.mailbox_pure(program, sigs)

    constraints =
      st
      |> Infer.deferred()
      |> Enum.reject(&is_map_key(&1, :placeholder))
      |> Enum.with_index()
      |> Enum.map(fn {c, id} ->
        %{
          id: id,
          sub: Types.substitute(c.sub, theta),
          sup: Types.substitute(c.sup, theta),
          kind: kind(c.kind, theta)
        }
      end)

    receives = for {:receive, info} <- Infer.events(st), do: info
    selection = selection(constraints, sigs)
    store = Store.new(constraints, selection)

    %{
      constraints: constraints,
      store: store,
      forced: Store.forced_top(store),
      selection: selection,
      receives: receives,
      spawns: spawns,
      pure: pure,
      roles: Infer.roles(st)
    }
  end

  defp kind({:app, head, f, s, o, i, g}, theta) do
    sub = &Types.substitute(&1, theta)
    {:app, head, sub.(f), sub.(s), sub.(o), sub.(i), g}
  end

  defp kind({:send, p, m}, theta),
    do: {:send, Types.substitute(p, theta), Types.substitute(m, theta)}

  defp kind(_kind, _theta), do: nil

  # An application of an overloaded function to a ground argument that only one of its
  # arrows accepts must select this arrow (Lemma lem:recon-select of the paper): the
  # bracket of the application narrows the bracket of the arrow.
  defp selection(constraints, sigs) do
    for %{kind: {:app, head, _f, s, o, i, _g}} <- constraints,
        head != nil,
        %{arrows: arrows} <- [Map.get(sigs, head)],
        is_list(arrows),
        length(arrows) > 1,
        Types.ground?(s),
        not Types.empty?(s),
        arrow <- arrows,
        others = Types.union_all(for a <- arrows, a != arrow, do: a.s),
        not Types.subtype?(s, others),
        bound <- narrowing(o, i, arrow),
        do: bound
  end

  defp narrowing(o, i, arrow) do
    input = if v = Store.variable(i), do: [{:upper, v, arrow.i}], else: []

    output =
      cond do
        v = Store.variable(arrow.o) -> [{:upper, v, o}]
        v = Store.variable(o) -> [{:lower, v, arrow.o}]
        true -> []
      end

    input ++ output
  end

  # The spawns in an order that extends the dependencies; those on a cycle, and those
  # that depend on a failure, fail.
  defp solve_all(spawns, world, derived, dependencies, results) do
    pending = Enum.reject(spawns, &is_map_key(results, &1.occurrence))

    ready =
      Enum.filter(pending, fn s ->
        Enum.all?(dependencies[s.occurrence], &is_map_key(results, &1))
      end)

    cond do
      pending == [] ->
        results

      ready == [] ->
        Enum.reduce(pending, results, fn s, acc ->
          unsolved = Enum.reject(dependencies[s.occurrence], &is_map_key(results, &1))
          Map.put(acc, s.occurrence, {:error, {:cycle, unsolved}})
        end)

      true ->
        results =
          Enum.reduce(ready, results, fn s, results ->
            deps = dependencies[s.occurrence]
            failed = Enum.filter(deps, &match?({:error, _}, results[&1]))

            result =
              if failed != [] do
                {:error, {:failed, failed}}
              else
                solved =
                  for other <- spawns, other.occurrence in deps do
                    {:ok, t} = results[other.occurrence]
                    {other, t}
                  end

                Solve.interface(world, s, derived[s.occurrence], solved)
              end

            Map.put(results, s.occurrence, result)
          end)

        solve_all(spawns, world, derived, dependencies, results)
    end
  end
end
