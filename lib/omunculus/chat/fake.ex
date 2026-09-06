defmodule Omunculus.Chat.Fake do
  @moduledoc false
  @behaviour Omunculus.Chat

  def new(turns) when is_list(turns) do
    {:ok, pid} = Agent.start_link(fn -> turns end)
    %{mod: __MODULE__, pid: pid}
  end

  @impl true
  def complete(%{pid: pid}, _messages, _tools) do
    Agent.get_and_update(pid, fn
      [turn | rest] -> {normalize(turn), rest}
      [] -> {{:error, :no_scripted_turns}, []}
    end)
  end

  defp normalize({:ok, result}), do: {:ok, result}
  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize(result) when is_map(result), do: {:ok, result}
end
