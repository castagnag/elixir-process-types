defmodule ProcessTypesTest do
  use ExUnit.Case

  test "the copied type representation has type variables, tallying and recursive types" do
    assert Code.ensure_loaded?(ProcessTypes.Descr)

    for {name, arity} <- [fun_apply: 2, var: 1, tally: 2, substitute: 2, recursive: 1] do
      assert function_exported?(ProcessTypes.Descr, name, arity)
    end
  end
end
