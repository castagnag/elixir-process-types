defmodule ProcessTypes.Types do
  @moduledoc """
  The types of the paper, as `Module.Types.Descr` types.

  This is the only module that calls `Module.Types.Descr`, the private type
  representation of the Elixir compiler. The two type constructors that the paper
  adds to those of Elixir are encoded with Descr's function types, whose arities are
  disjoint:

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

  alias Module.Types.Descr, as: D
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
  def arrow(s, o, i, t), do: D.fun([D.union(s, mho()), pid(o), read_cap(i)], t)

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
        case D.fun_apply(f, [union(s, mho()), pid(o), read_cap(i)]) do
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
      case D.fun_apply(p, [term()]) do
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
         {:badarg, [s1, w, r], _} <- D.fun_apply(t, [term(), term(), term()]),
         {:ok, i} <- D.fun_apply(r, []),
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
      case D.fun_apply(f, [term(), term(), term()]) do
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
      case D.tuple_fetch(t, k) do
        {_optional?, c} -> c
        _ -> none()
      end
    end
  end

  # Printing

  @doc "The type in the syntax of annotations (GRAMMAR.md, §5)."
  def to_string(t), do: t |> to_syntax() |> TypeSyntax.to_string()

  @doc "Reads Descr's quoted form of `t` back as a source type (see `ProcessTypes.TypeSyntax`)."
  def to_syntax(t), do: t |> D.to_quoted() |> back()

  defp back({:__block__, _, [x]}), do: back(x)
  defp back(a) when is_atom(a), do: {:atom, a}
  defp back([{:->, _, [args, ret]}]), do: back_fun(args, ret)
  defp back({:or, _, [a, b]}), do: {:or, back(a), back(b)}
  defp back({:and, _, [a, b]}), do: {:and, back(a), back(b)}
  defp back({:not, _, [a]}), do: {:not, back(a)}
  defp back({:{}, _, [{:..., _, nil}]}), do: :tuple

  defp back({:{}, _, elems} = q) do
    if Enum.any?(elems, &match?({:..., _, nil}, &1)),
      do: {:raw, q},
      else: {:tuple, Enum.map(elems, &back/1)}
  end

  defp back({name, _, []}) when name in [:integer, :atom, :boolean, :term, :none], do: name
  defp back(q), do: {:raw, q}

  # A pid: (t -> ℧)
  defp back_fun([arg], {:port, _, []}) do
    case back(arg) do
      :none -> {:pid, :none}
      t -> {:pid, t}
    end
  end

  # An arrow: (s or ℧, pid(o), (-> i) -> t)
  defp back_fun([s1, w, r], ret) do
    with {:pid, o} <- back(w),
         {:ok, i} <- back_read_cap(r) do
      s = s1 |> flatten_or() |> Enum.reject(&match?({:port, _, []}, &1))

      domain = if s == [], do: :none, else: s |> Enum.map(&back/1) |> Enum.reduce(&{:or, &2, &1})
      ret = back(ret)

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

  defp back_fun(args, ret), do: {:raw, [{:->, [], [args, ret]}]}

  defp back_read_cap({:__block__, _, [x]}), do: back_read_cap(x)
  defp back_read_cap([{:->, _, [[], i]}]), do: {:ok, back(i)}
  defp back_read_cap(_), do: :error

  defp flatten_or({:or, _, [a, b]}), do: flatten_or(a) ++ flatten_or(b)
  defp flatten_or(q), do: [q]
end
