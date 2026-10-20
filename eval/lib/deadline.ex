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

  @spec run(pos_integer | :infinity, (-> {:ok, term} | {:error, term})) :: tuple
  def run(seconds, fun) do
    timeout = if seconds == :infinity, do: :infinity, else: seconds * 1000
    work = Task.async(fun)

    case Task.yield(work, timeout) || Task.shutdown(work, :brutal_kill) do
      {:ok, {:ok, played}} -> {{:ok, played}, played}
      {:ok, {:error, reason}} -> {{:error, reason}, nil}
      nil -> {{:error, :timeout}, nil}
    end
  end
end
