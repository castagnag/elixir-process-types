defmodule Mix.Tasks.Playground do
  @shortdoc "Serves the playground on http://localhost:4000"
  @moduledoc """
  Serves the playground (`ProcessTypes.Web`) on localhost, by default on port 4000.

      mix playground
      mix playground --port 4100

  The server listens on the loopback interface only.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [port: :integer])
    port = opts[:port] || 4000
    Mix.Task.run("app.start")
    {:ok, _} = Bandit.start_link(plug: ProcessTypes.Web, ip: {127, 0, 0, 1}, port: port)
    Mix.shell().info("Playground on http://localhost:#{port} (Ctrl-C twice to stop)")
    Process.sleep(:infinity)
  end
end
