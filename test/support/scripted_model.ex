defmodule Omunculus.Test.ScriptedModel do
  @moduledoc false

  def start_link do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def put(id, fun) when is_binary(id) and is_function(fun) do
    :ok = Agent.update(__MODULE__, &Map.put(&1, id, fun))
  end

  def new(spec) when is_map(spec) do
    id = spec["params"]["script"]

    fn assembled, tools, call, record, execution ->
      invoke(fetch!(id), assembled, tools, call, record, execution)
    end
  end

  defp fetch!(id), do: Agent.get(__MODULE__, &Map.fetch!(&1, id))

  defp invoke(fun, assembled, tools, call, record, execution) when is_function(fun, 5),
    do: fun.(assembled, tools, call, record, execution)

  defp invoke(fun, assembled, tools, call, record, _execution) when is_function(fun, 4),
    do: fun.(assembled, tools, call, record)

  defp invoke(fun, assembled, tools, call, record, _execution) when is_function(fun, 3) do
    with {:ok, text} <- fun.(assembled, tools, call) do
      :ok = record.(text)
      {:ok, text}
    end
  end
end
