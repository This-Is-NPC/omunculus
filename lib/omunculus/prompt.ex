defmodule Omunculus.Prompt do
  @moduledoc """
  The assembled prompt of a run: its `instructions`, which stay the same
  from one run of an agent to the next while the configuration and the
  ceiling do, and the `context` of this run. Model adapters send them
  apart, so a provider can serve the instructions from its cache.
  """

  @enforce_keys [:instructions, :context]
  defstruct [:instructions, :context]

  @type t :: %__MODULE__{instructions: String.t(), context: String.t()}

  @doc "The whole prompt: the instructions, then the context."
  @spec text(t) :: String.t()
  def text(%__MODULE__{instructions: instructions, context: context}),
    do: [instructions, context] |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")
end
