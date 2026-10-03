defmodule ProcessTypes.Diagnostic do
  @moduledoc "An error found in a program, at a line of its source."

  defstruct [:line, :message, severity: :error]

  @type t :: %__MODULE__{
          line: pos_integer() | nil,
          message: String.t(),
          severity: :error | :warning
        }

  def error(line, message), do: %__MODULE__{line: line, message: message}

  def format(%__MODULE__{line: line, message: message, severity: severity}, file \\ "nofile"),
    do: "#{file}:#{line || 1}: #{severity}: #{message}"
end
