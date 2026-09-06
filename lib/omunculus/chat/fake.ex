defmodule Omunculus.Chat.Fake do
  @moduledoc false
  @behaviour Omunculus.Chat

  def new(turns) when is_list(turns) do
    {:ok, pid} = Agent.start_link(fn -> turns end)
    %{mod: __MODULE__, pid: pid}
  end

  @impl true
  def complete(%{pid: pid}, messages, _tools) do
    Agent.get_and_update(pid, fn
      [turn | rest] -> {normalize(turn, messages), rest}
      [] -> {{:error, :no_scripted_turns}, []}
    end)
  end

  @doc "Scripted turn: a result map, an ok/error tuple, or a fun of the messages so far."
  def tool_call(name, args, id \\ "call") do
    %{
      content: nil,
      tool_calls: [
        %{"id" => id, "function" => %{"name" => name, "arguments" => Jason.encode!(args)}}
      ],
      usage: nil
    }
  end

  def text(content), do: %{content: content, tool_calls: nil, usage: nil}

  defp normalize(fun, messages) when is_function(fun, 1), do: normalize(fun.(messages), messages)
  defp normalize({:ok, result}, _), do: {:ok, result}
  defp normalize({:error, reason}, _), do: {:error, reason}
  defp normalize(result, _) when is_map(result), do: {:ok, result}
end
