defmodule ProcessTypes.MixProject do
  use Mix.Project

  def project do
    [
      app: :process_types,
      version: "0.2.0",
      description: "Process Types for Elixir: a prototype type checker for Elixir processes",
      package: [licenses: ["Apache-2.0"]],
      # Types are built with ProcessTypes.Descr, the copy in lib/vendor/ of the type
      # representation of the compiler from Guillaume Duboc's branch with type
      # variables, tallying and recursive types; it is compiled with the project.
      elixir: "~> 1.20.4",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ProcessTypes.Application, []}
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
