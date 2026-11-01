defmodule ProcessTypes.Types do
  @moduledoc """
  The types of the paper, as `ProcessTypes.Descr` types.

  This is the only module that calls `ProcessTypes.Descr`, a copy of the type
  representation of the Elixir compiler, `Module.Types.Descr`, taken from Guillaume
  Duboc's branch `type-variables` of https://github.com/gldubc/elixir: its type
  variables, tallying and recursive types are Guillaume Duboc's work (see
  `lib/vendor/README.md`). The two type constructors that the paper adds to those of
  Elixir are encoded with Descr's function types, whose arities are disjoint:

  | paper          | Descr                                    |
  |----------------|------------------------------------------|
  | `() -> i`      | `fun([], i)`, the read capability        |
  | `pid(t)`       | `fun([t], ℧)`, the write capability      |
  | `s ->_o^i t`   | `fun([s or ℧, pid(o), () -> i], t)`      |

  where ℧ is `port()`, a type that no value of the language inhabits. In an arrow it
  is the point that keeps the value component of the domain nonempty (Section 4.1 of
  the paper); in a pid it is the unit that a write returns.

  Two properties of Descr matter here, both harmless for the encoding: a function type
  that contains no positive arrow is never empty, so that `fun([none()], ℧)`, our
  `pid()`, is not the top of the unary functions (the others belong to no type of the
  language, like the read capabilities in the model of the paper); and Descr's own
  printer drops negated arrows, which `to_string/1` therefore cannot show either.
  """

  alias ProcessTypes.Descr, as: D
  alias ProcessTypes.TypeSyntax

  @type t :: term()

  # Constants and constructors

  def term, do: D.term()
  def none, do: D.none()
  def integer, do: D.integer()
  def atom, do: D.atom()
  def atom(atoms) when is_list(atoms), do: D.atom(atoms)
  def boolean, do: D.boolean()
  def tuple, do: D.tuple()
  def tuple(components) when is_list(components), do: D.tuple(components)

  defp mho, do: D.port()

  @doc "The pid type `pid(t)`."
  def pid(t), do: D.fun([t], mho())

  @doc "The top process type `pid()`, that is, `pid(none())`."
  def pid, do: pid(none())

  defp read_cap(i), do: D.fun([], i)

  @doc "The decorated arrow `s ->_o^i t`, written `(s -> t)@[o, i]`."
  def arrow(s, o, i, t), do: pointed_arrow(pointed(s), o, i, t)

  @doc """
  The pointed domain `s or ℧` of an arrow whose domain is `s` (Section 4.1 of the
  paper): the value component of the input of an arrow, never empty.
  """
  def pointed(s), do: D.union(s, mho())

  @doc """
  The arrow `s ->_o^i t`, given its pointed domain `ps`, that is, `pointed(s)`. Inside
  the equations of a recursive type, where `pointed/1` cannot be applied to a node of
  the same system (`recursive/1`), the pointed domain is an equation of its own.
  """
  def pointed_arrow(ps, o, i, t), do: D.fun([ps, pid(o), read_cap(i)], t)

  @doc "The top function type `fun()`, that is, the arrow `none() ->_term()^none() term()`."
  def fun, do: arrow(none(), term(), none(), term())

  # Connectives and relations

  defdelegate union(s, t), to: D
  defdelegate intersection(s, t), to: D
  defdelegate difference(s, t), to: D
  defdelegate negation(t), to: D
  defdelegate subtype?(s, t), to: D
  defdelegate equal?(s, t), to: D
  defdelegate empty?(t), to: D

  def union_all(types), do: Enum.reduce(types, none(), &union(&2, &1))
  def intersection_all(types), do: Enum.reduce(types, term(), &intersection(&2, &1))

  # Type variables and tallying (Section 8 of the paper)

  @doc """
  A fresh type variable. `name` only serves for printing: two calls with the same name
  give two distinct variables.
  """
  defdelegate var(name), to: D

  @doc "The variables that occur in `t` (those that matter: `t` depends on them)."
  defdelegate vars(t), to: D

  @doc """
  The variables that occur in `t` syntactically, including those that do not matter:
  much cheaper than `vars/1` on recursive types, and enough to substitute them all.
  """
  defdelegate syntactic_vars(t), to: D

  @doc "Whether `t` contains no type variable."
  def ground?(t), do: MapSet.size(D.vars(t)) == 0

  @doc """
  Applies a substitution, a map from variables to types, simultaneously: the images
  are not substituted again.
  """
  defdelegate substitute(t, substitution), to: D

  @doc """
  Solves a list of constraints `{s, t}`, read s ≤ t, by tallying (Castagna et al.): the
  result is a finite list of substitutions, each of which satisfies every constraint,
  and of which every solution is an instance; `[]` when there is no solution.
  """
  def tally(constraints), do: D.tally(constraints)

  @doc """
  Like `tally/1`, but searches for one solution only: `[σ]`, or `[]`, in theory exactly
  when `tally/1` answers `[]` (in practice the two can disagree where Descr's
  `subtype?/2` errs).
  """
  def tally_first(constraints), do: D.tally_first(constraints)

  # Recursive types

  @doc """
  The recursive types defined by `equations`, a map from keys to generators: each
  generator receives `recur`, which maps a key to the node of its equation, and returns
  the body of the equation. Returns the map from keys to nodes.

  The constructors (`tuple/1`, `pid/1`, `pointed_arrow/4`) keep the nodes they are given
  unevaluated, but the connectives evaluate them: in a generator, a connective may be
  applied to the nodes of the system only through the `bare_*` connectives, and only at
  the top of the body, never in an argument of a constructor. The equations must be
  contractive (every cycle passes through a constructor), or evaluation loops.
  """
  defdelegate recursive(equations), to: D

  @doc "Union without simplification, for the body of a recursive equation."
  defdelegate bare_union(s, t), to: D

  @doc "Intersection without simplification, for the body of a recursive equation."
  defdelegate bare_intersection(s, t), to: D

  @doc "Negation without simplification, for the body of a recursive equation."
  defdelegate bare_negation(t), to: D

  @doc "The pointed domain `s or ℧`, for the body of a recursive equation."
  def bare_pointed(s), do: D.bare_union(s, mho())

  # Eliminations

  @doc """
  The least type `u` such that `f ≤ s ->_o^i u`: the result of applying a function of
  type `f` to an argument of type `s` at the bracket `[o, i]` (rule t-app with
  subsumption). The argument is pointed, so that it is never empty.
  """
  def apply(f, s, o, i) do
    cond do
      empty?(f) ->
        {:ok, none()}

      not subtype?(f, fun()) ->
        :badfun

      true ->
        case fun_apply(f, [union(s, mho()), pid(o), read_cap(i)]) do
          {:ok, u} -> {:ok, u}
          {:badarg, _, _} -> :badarg
          _ -> :badfun
        end
    end
  end

  @doc """
  The interface of a process type `p`: the largest `s` such that `p ≤ pid(s)`, that
  is, the type of the messages that every pid of type `p` accepts.
  """
  def interface(p) do
    if empty?(p) do
      term()
    else
      case fun_apply(p, [term()]) do
        {:ok, _} -> term()
        {:badarg, [s], _} -> s
        _ -> none()
      end
    end
  end

  @doc """
  If `t` is equivalent to a single arrow `s ->_o^i u`, returns `{:ok, {s, o, i, u}}`;
  otherwise `:error`.
  """
  def arrow_parts(t) do
    with false <- empty?(t),
         true <- subtype?(t, fun()),
         {:badarg, [s1, w, r], _} <- fun_apply(t, [term(), term(), term()]),
         {:ok, i} <- fun_apply(r, []),
         s = difference(s1, mho()),
         o = interface(w),
         {:ok, u} <- apply(t, s, o, i),
         true <- equal?(arrow(s, o, i, u), t) do
      {:ok, {s, o, i, u}}
    else
      _ -> :error
    end
  end

  @doc """
  The union of the argument types that a function of type `f` accepts at some
  bracket, used only to propagate expected types.
  """
  def value_domain(f) do
    if empty?(f) or not subtype?(f, fun()) do
      none()
    else
      case fun_apply(f, [term(), term(), term()]) do
        {:badarg, [s1 | _], _} -> difference(s1, mho())
        {:ok, _} -> term()
        _ -> none()
      end
    end
  end

  @doc "Whether `t` is a type of tuples of arity `n`."
  def tuple_of_arity?(t, n), do: subtype?(t, tuple(List.duplicate(term(), n)))

  @doc """
  The projection `π_k(t)` (0-based) of a type `t` of tuples whose arity exceeds `k`;
  `none()` when `t` is empty.
  """
  def tuple_component(t, k) do
    if empty?(t) do
      none()
    else
      case D.tuple_fetch(unfold(t), k) do
        {_optional?, c} -> c
        _ -> none()
      end
    end
  end

  @doc """
  The summands of a type `t` of tuples of arity `n`: a list of products whose union is
  equivalent to `t`, under every substitution of its variables (GRAMMAR.md, §10). The
  products are those of the normal form of `t`, in which Descr has merged those that differ
  in one component. Returns `[t]` when `t` has no such form, because a variable occurs at
  its top or it is not a type of tuples of arity `n`, and when it is empty.
  """
  def tuple_summands(t, n) do
    u = unfold(t)
    top_variable? = match?({:type_variables, _}, u) and not ground?(u)

    with false <- top_variable?,
         true <- tuple_of_arity?(u, n),
         tuples = intersection(u, tuple(List.duplicate(term(), n))),
         [_ | _] = summands <-
           tuples
           |> D.domain_to_args()
           |> Enum.reject(fn components -> Enum.any?(components, &empty?/1) end) do
      Enum.map(summands, &tuple/1)
    else
      _ -> [t]
    end
  end

  # Descr's eliminators do not take a recursive node: unfold it first, once is enough
  # for the equations of ProcessTypes.TypeGraph, whose bodies are never bare nodes.
  defp fun_apply(f, args), do: D.fun_apply(unfold(f), args)

  defp unfold(t) do
    case D.to_descr(t) do
      ^t -> t
      u -> unfold(u)
    end
  end

  # Printing

  @doc "The type in the syntax of annotations (GRAMMAR.md, §5)."
  def to_string(t), do: t |> to_syntax() |> TypeSyntax.to_string()

  @doc """
  Reads Descr's quoted form of `t` back as a source type (see `ProcessTypes.TypeSyntax`).

  A recursive type is read back as `{:rec, x, t}`. The point ℧ belongs to no type of
  the language: like the junk of the readback of the paper (Appendix A), it is read
  back as `none()`, and so disappears from unions.
  """
  def to_syntax(t), do: t |> D.to_quoted() |> back(MapSet.new())

  @doc """
  `t` with its equivalent recursive nodes merged, as SSTT's `factorize` (patch 10 of
  `lib/vendor/README.md`): an equivalent type that prints each recursive type once.
  """
  def factorize(t), do: D.factorize(t)

  defp back({:__block__, _, [x]}, b), do: back(x, b)
  defp back({:rec, _, [{x, _, nil}, body]}, b), do: rec(x, back(body, MapSet.put(b, x)))

  defp back({x, _, nil}, b) when is_atom(x),
    do: if(MapSet.member?(b, x), do: {:recvar, x}, else: {:var, x})

  defp back(a, _b) when is_atom(a), do: {:atom, a}
  defp back([{:->, _, [args, ret]}], b), do: back_fun(args, ret, b)
  defp back({:or, _, [l, r]}, b), do: or_syntax(back(l, b), back(r, b))
  defp back({:and, _, [l, r]}, b), do: and_syntax(back(l, b), back(r, b))
  defp back({:not, _, [a]}, b), do: not_syntax(back(a, b))
  defp back({:{}, _, [{:..., _, nil}]}, _b), do: :tuple

  defp back({:{}, _, elems} = q, b) do
    if Enum.any?(elems, &match?({:..., _, nil}, &1)),
      do: {:raw, q},
      else: {:tuple, Enum.map(elems, &back(&1, b))}
  end

  defp back({:port, _, []}, _b), do: :none
  defp back({name, _, []}, _b) when name in [:integer, :atom, :boolean, :term, :none], do: name
  defp back(q, _b), do: {:raw, q}

  defp or_syntax(:none, t), do: t
  defp or_syntax(t, :none), do: t
  defp or_syntax(s, t), do: {:or, s, t}

  defp and_syntax(:term, t), do: t
  defp and_syntax(t, :term), do: t
  defp and_syntax(s, t), do: {:and, s, t}

  defp not_syntax(:none), do: :term
  defp not_syntax(:term), do: :none
  defp not_syntax(t), do: {:not, t}

  # A binder that its body does not use is dropped.
  defp rec(x, body), do: if(free?(body, x), do: {:rec, x, body}, else: body)

  defp free?({:recvar, x}, x), do: true
  defp free?({:rec, x, _}, x), do: false
  defp free?(t, x) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.any?(&free?(&1, x))
  defp free?(ts, x) when is_list(ts), do: Enum.any?(ts, &free?(&1, x))
  defp free?(_, _), do: false

  # A pid: (t -> ℧)
  defp back_fun([arg], {:port, _, []}, b) do
    case back(arg, b) do
      :none -> {:pid, :none}
      t -> {:pid, t}
    end
  end

  # An arrow: (s or ℧, pid(o), (-> i) -> t). The pointed domain reads back as s, since
  # ℧ reads back as none().
  defp back_fun([s1, w, r], ret, b) do
    with {:pid, o} <- back(w, b),
         {:ok, i} <- back_read_cap(r, b) do
      domain = back(s1, b)
      ret = back(ret, b)

      cond do
        domain == :none and o == :term and i == :none and ret == :term ->
          :fun

        true ->
          args =
            case domain do
              {:tuple, elems} when length(elems) != 1 -> elems
              _ -> [domain]
            end

          decorations = if o == :none and i == :term, do: nil, else: {o, i}
          {:arrow, args, ret, decorations}
      end
    else
      _ -> {:raw, [{:->, [], [[s1, w, r], ret]}]}
    end
  end

  defp back_fun(args, ret, _b), do: {:raw, [{:->, [], [args, ret]}]}

  defp back_read_cap({:__block__, _, [x]}, b), do: back_read_cap(x, b)
  defp back_read_cap([{:->, _, [[], i]}], b), do: {:ok, back(i, b)}
  defp back_read_cap(_, _b), do: :error
end
