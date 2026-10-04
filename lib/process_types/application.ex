defmodule ProcessTypes.Application do
  @moduledoc false

  use Application

  # The runner of the playground's checks (ProcessTypes.Web.Runner).
  @impl true
  def start(_type, _args) do
    Supervisor.start_link([ProcessTypes.Web.Runner], strategy: :one_for_one, name: ProcessTypes.Supervisor)
  end
end
