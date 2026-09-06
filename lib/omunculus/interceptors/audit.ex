defmodule Omunculus.Interceptors.Audit do
  @moduledoc """
  Observe-only interceptor: lets every envelope through. Its value is the
  per-interceptor counters the Event Core keeps (`interceptor_stats/1`),
  which prove that a configured lane changes nothing in the log.
  """
  @behaviour Omunculus.Interceptor

  @impl true
  def intercept(_envelope, _options), do: :deliver
end
