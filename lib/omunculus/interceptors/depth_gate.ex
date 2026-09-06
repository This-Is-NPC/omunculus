defmodule Omunculus.Interceptors.DepthGate do
  @moduledoc """
  Rejects `task.delegated` deliveries whose `to_depth` exceeds `max_depth`.
  Takes the depth policy out of the Run: the node only asks, the lane decides.
  """
  @behaviour Omunculus.Interceptor

  @impl true
  def intercept(%{type: "task.delegated", payload: %{"to_depth" => depth}}, options) do
    max = options["max_depth"] || options[:max_depth] || 1

    if depth > max,
      do: {:reject, "to_depth #{depth} exceeds max_depth #{max}"},
      else: :deliver
  end

  def intercept(_envelope, _options), do: :deliver
end
