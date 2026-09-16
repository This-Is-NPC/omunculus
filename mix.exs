defmodule Omunculus.MixProject do
  use Mix.Project

  def project do
    [
      app: :omunculus,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: releases(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Omunculus.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:bench), do: ["lib", "bench/lib"]
  defp elixirc_paths(_), do: ["lib"]

  defp releases(:bench), do: [benchmark: [include_executables_for: [:unix]]]
  defp releases(_), do: []

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:toml, "~> 0.7"},
      {:exqlite, "~> 0.40"},
      {:req, "~> 0.5"}
    ]
  end
end
