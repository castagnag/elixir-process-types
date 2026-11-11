defmodule ProcessTypes.Backend do
  @moduledoc """
  How the checker discharges what the algorithmic rules of Fig. `fig:inference` of the
  paper emit, and where the decorations of annotations come from (GRAMMAR.md, §9).

  `ProcessTypes.Backend.Ground` knows every decoration and checks each constraint at
  once; every fresh variable of the rules takes its least solution, or the solution
  of the declarative rule (the bracket [t, t] of rule t-spawn). `ProcessTypes.Backend.Infer`
  decorates annotations with type variables, records the constraints that mention
  variables, and solves them at the end by tallying.

  The checker calls the backend with the *occurrence* of an annotated construct in the
  program (`{:def, module, name, arity}`, `{:fn, line, column}`,
  `{:spawn, line, column}` or `:main`): its decorations are minted once per occurrence
  and shared by every premise that types it (Section 8.1 of the paper).

  The state is a map holding at least the diagnostics found so far, under `:diags`. A
  diagnostic is given as a function of `inst`, which turns a type into the type to
  print: the identity when a constraint is checked at once, an instance of the solution
  of the constraints generated before when a deferred one fails.
  """

  alias ProcessTypes.{Diagnostic, Types}

  @type state :: %{required(:diags) => [Diagnostic.t()], optional(atom()) => term()}
  @type inst :: (Types.t() -> Types.t())
  @type occurrence :: term()
  @type arrow :: %{
          arity: non_neg_integer(),
          s: Types.t(),
          o: Types.t(),
          i: Types.t(),
          t: Types.t()
        }

  @doc "The initial state; `opts` are those of `ProcessTypes.Checker.check/2`."
  @callback new(opts :: keyword()) :: state

  @doc "`:ground` or `:infer`."
  @callback mode() :: :ground | :infer

  @doc "Requires `sub ≤ sup`."
  @callback require_subtype(
              state,
              sub :: Types.t(),
              sup :: Types.t(),
              line :: pos_integer() | nil,
              diagnostic :: (inst -> Diagnostic.t())
            ) :: state

  @doc """
  Rule i-app: the type of the application of a function of type `f` to an argument of
  type `s` at the bracket `[o, i]`. The diagnostic receives the reason of the failure
  (`:badfun`, `:badarg`, or `:unsat` when the application is typable alone but not
  with the rest of the program) and `inst`.
  """
  @callback apply(
              state,
              f :: Types.t(),
              s :: Types.t(),
              o :: Types.t(),
              i :: Types.t(),
              line :: pos_integer() | nil,
              diagnostic :: (atom(), inst -> Diagnostic.t())
            ) :: {Types.t(), state}

  @doc "Rule pe-tuple: the components of `t`, a type of tuples of arity `n`."
  @callback projections(
              state,
              t :: Types.t(),
              n :: non_neg_integer(),
              line :: pos_integer() | nil,
              diagnostic :: (inst -> Diagnostic.t())
            ) :: {[Types.t()], state}

  @doc "The type that the annotation `source` (`$interface`, `$self_interface`) denotes at the occurrence."
  @callback annotation(state, occurrence, source :: term(), defs :: map(), scope :: atom()) ::
              {{:ok, Types.t()} | {:error, String.t()}, state}

  @doc "The arrows of the function annotation `source` (`$ L`) at the occurrence (rule i-abs)."
  @callback annotation_arrows(state, occurrence, source :: term(), defs :: map(), scope :: atom()) ::
              {{:ok, [arrow]} | {:error, String.t()}, state}

  @doc """
  The bracket of an unannotated `fn` for this typing of its body: fresh decorations in
  inference mode, not shared with the other premises that type the `fn`, since it has no
  annotation to decorate (GRAMMAR.md, §6); `nil` in ground mode, where the expected-type
  rule applies. The occurrence only names the variables.
  """
  @callback fn_bracket(state, occurrence) :: {{Types.t(), Types.t()} | nil, state}

  @doc """
  The bracket `[o, i]` at which runs the body of a process of interface `t`, spawned
  at the occurrence or the main process (rule i-spawn: o ≤ t ≤ i).
  """
  @callback process_bracket(
              state,
              occurrence,
              t :: Types.t(),
              line :: pos_integer() | nil,
              diagnostic :: (inst -> Diagnostic.t())
            ) :: {{Types.t(), Types.t()}, state}

  @doc """
  Rule i-spawn-alt (reconstruction, GRAMMAR.md §11): the bracket `[o, i]` of the body of
  a `spawn` without interface, or of the main process, and its pid variable γ; no
  constraint relates them. Only the inference backend, when it records, implements it.
  """
  @callback spawn_alt(state, occurrence, line :: pos_integer() | nil) ::
              {{Types.t(), Types.t()}, Types.t(), state}

  @doc """
  A fresh type for the variable that the pattern of a `receive` branch binds at its root,
  above the refined type `r` of the branch (reconstruction); `r` itself when the backend
  does not record.
  """
  @callback capture(state, r :: Types.t(), line :: pos_integer() | nil) :: {Types.t(), state}

  @doc """
  Tells the backend what the checker does, for the reconstruction: `{:kind, k}` describes
  the next constraint, `{:receive, info}` a use of rule i-receive. Ignored unless the
  backend records.
  """
  @callback note(state, event :: term()) :: state

  @doc """
  Solves what was deferred. `reported` are the types that `instance/2` will be asked
  for: their variables must keep their most precise solution.
  """
  @callback finish(state, reported :: [Types.t()]) :: state

  @doc "The type to report for `t` once `finish/1` has run: an instance of the solution."
  @callback instance(state, t :: Types.t()) :: Types.t()
end

defmodule ProcessTypes.Backend.Ground do
  @moduledoc "Every decoration is known (ground mode): constraints are checked at once."

  @behaviour ProcessTypes.Backend

  alias ProcessTypes.{TypeSyntax, Types}

  @impl true
  def new(_opts), do: %{diags: []}

  @impl true
  def mode, do: :ground

  @impl true
  def require_subtype(st, sub, sup, _line, diagnostic) do
    if Types.subtype?(sub, sup), do: st, else: %{st | diags: [diagnostic.(& &1) | st.diags]}
  end

  @impl true
  def apply(st, f, s, o, i, _line, diagnostic) do
    case Types.apply(f, s, o, i) do
      {:ok, u} -> {u, st}
      reason -> {Types.none(), %{st | diags: [diagnostic.(reason, & &1) | st.diags]}}
    end
  end

  @impl true
  def projections(st, t, n, _line, _diagnostic),
    do: {for(k <- 0..(n - 1)//1, do: Types.tuple_component(t, k)), st}

  @impl true
  def annotation(st, _occurrence, source, defs, scope),
    do: {TypeSyntax.to_descr(source, defs, scope), st}

  @impl true
  def annotation_arrows(st, _occurrence, source, defs, scope),
    do: {TypeSyntax.arrows(source, defs, scope), st}

  @impl true
  def fn_bracket(st, _occurrence), do: {nil, st}

  @impl true
  def process_bracket(st, _occurrence, t, _line, _diagnostic), do: {{t, t}, st}

  @impl true
  def spawn_alt(_st, _occurrence, _line),
    do: raise(ArgumentError, "ground mode does not reconstruct interfaces")

  @impl true
  def capture(st, r, _line), do: {r, st}

  @impl true
  def note(st, _event), do: st

  @impl true
  def finish(st, _reported), do: st

  @impl true
  def instance(_st, t), do: t
end
