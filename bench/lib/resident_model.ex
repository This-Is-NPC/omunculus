defmodule Omunculus.Benchmark.ResidentModel do
  @moduledoc false

  alias Omunculus.Model.OpenAI

  def new(spec) when is_map(spec) do
    inner = OpenAI.new(spec["params"])

    fn assembled, tools, call, record, execution ->
      case Process.get(:omunculus_bench) do
        {parent, agent} -> send(parent, {:resident, agent, byte_size(assembled)})
        nil -> :ok
      end

      inner.(assembled, tools, call, record, execution)
    end
  end
end
