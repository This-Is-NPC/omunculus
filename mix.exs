defmodule Omunculus.MixProject do
  use Mix.Project

  def project do
    [
      app: :omunculus,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {Omunculus.Application, []}
    ]
  end

  defp escript do
    [main_module: Omunculus.CLI, name: "omunculus"]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:toml, "~> 0.7"},
      {:exqlite, "~> 0.40"},
      {:bypass, "~> 2.1", only: :test}
    ]
  end
end
