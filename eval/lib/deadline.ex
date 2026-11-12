defmodule EquivalentExchange.Deadline do
  @moduledoc "Runs an evaluation conversation with an optional elapsed-time limit."

  @spec parse(String.t()) :: pos_integer | :infinity
  def parse("infinity"), do: :infinity

  def parse(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds > 0 -> seconds
      _ -> raise ArgumentError, "--timeout expects positive seconds or infinity, got: #{value}"
    end
  end

  # How often `over`, when given, is asked.
  @poll_ms 3000

  @doc """
  Runs `fun` until it returns, `seconds` pass or `over` (a function asked every
  few seconds) says true: `{:error, :timeout}` or `{:error, :budget}`.
  """
  @spec run(
          pos_integer | :infinity,
          (-> {:ok, term} | {:error, term}),
          non_neg_integer,
          (-> boolean) | nil
        ) ::
          tuple
  def run(seconds, fun, elapsed_ms \\ 0, over \\ nil) do
    timeout = if seconds == :infinity, do: :infinity, else: max(seconds * 1000 - elapsed_ms, 0)
    if timeout == 0, do: {{:error, :timeout}, nil}, else: within(timeout, fun, over)
  end

  defp within(timeout, fun, over), do: watch(Task.async(fun), timeout, over)

  defp watch(work, timeout, over) do
    slice = if over, do: min(timeout, @poll_ms), else: timeout

    case Task.yield(work, slice) do
      {:ok, {:ok, played}} -> {{:ok, played}, played}
      {:ok, {:error, reason}} -> {{:error, reason}, nil}
      {:exit, reason} -> exit(reason)
      nil -> waited(work, timeout, slice, over)
    end
  end

  defp waited(work, timeout, slice, over) do
    cond do
      over && over.() -> stop(work, :budget)
      timeout != :infinity and timeout <= slice -> stop(work, :timeout)
      true -> watch(work, if(timeout == :infinity, do: :infinity, else: timeout - slice), over)
    end
  end

  defp stop(work, reason) do
    Task.shutdown(work, :brutal_kill)
    {{:error, reason}, nil}
  end
end
