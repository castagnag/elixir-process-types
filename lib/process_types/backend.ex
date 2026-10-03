defmodule ProcessTypes.Backend do
  @moduledoc """
  How the checker discharges what the algorithmic rules of Section 8.2.2 of the paper
  emit.

  Every rule of `ProcessTypes.Checker` states its subtyping constraints through
  `require_subtype/4`, obtains the result of an application (rule i-app) through
  `apply/6`, and the projection of a matched tuple (rule pe-tuple) through
  `project/3`. `ProcessTypes.Backend.Ground` discharges them at once, since every
  decoration is known. A backend for the inference of Section 8 would instead return
  fresh type variables and collect the constraints, to be solved by tallying at the
  end.

  The state is a map holding at least the diagnostics found so far, under `:diags`.
  """

  alias ProcessTypes.{Diagnostic, Types}

  @type state :: %{required(:diags) => [Diagnostic.t()], optional(atom()) => term()}

  @doc "Requires `sub ≤ sup`; `diagnostic` describes the failure."
  @callback require_subtype(
              state,
              sub :: Types.t(),
              sup :: Types.t(),
              diagnostic :: (-> Diagnostic.t())
            ) ::
              state

  @doc """
  The type of the application of a function of type `f` to an argument of type `s` at
  the bracket `[o, i]`; `diagnostic` describes the failure, given its reason
  (`:badfun` or `:badarg`).
  """
  @callback apply(
              state,
              f :: Types.t(),
              s :: Types.t(),
              o :: Types.t(),
              i :: Types.t(),
              diagnostic :: (atom() -> Diagnostic.t())
            ) ::
              {Types.t(), state}

  @doc "The `k`-th component (0-based) of a type of tuples."
  @callback project(state, t :: Types.t(), k :: non_neg_integer()) :: {Types.t(), state}
end

defmodule ProcessTypes.Backend.Ground do
  @moduledoc "Discharges constraints at once: every decoration is known (Sections 3–6)."

  @behaviour ProcessTypes.Backend

  alias ProcessTypes.Types

  @impl true
  def require_subtype(st, sub, sup, diagnostic) do
    if Types.subtype?(sub, sup), do: st, else: %{st | diags: [diagnostic.() | st.diags]}
  end

  @impl true
  def apply(st, f, s, o, i, diagnostic) do
    case Types.apply(f, s, o, i) do
      {:ok, u} -> {u, st}
      reason -> {Types.none(), %{st | diags: [diagnostic.(reason) | st.diags]}}
    end
  end

  @impl true
  def project(st, t, k), do: {Types.tuple_component(t, k), st}
end
