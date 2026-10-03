defmodule ProcessTypes.MixProject do
  use Mix.Project

  def project do
    [
      app: :process_types,
      version: "0.1.0",
      # Types are built with Module.Types.Descr, a private compiler API that
      # changes between minor versions: stay on 1.20.x until we move to a
      # branch with type variables and tallying.
      elixir: "~> 1.20.4",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # The playground (mix playground) is served by Bandit; JSON is Elixir's own.
  defp deps do
    [
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.20"}
    ]
  end
end
