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

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
