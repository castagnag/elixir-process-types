defmodule ProcessTypesTest do
  use ExUnit.Case

  test "the type representation of the compiler is available" do
    assert Code.ensure_loaded?(Module.Types.Descr)
    assert function_exported?(Module.Types.Descr, :fun_apply, 2)
  end
end
