defmodule Omunculus.Benchmark.ResidentModel do
  @moduledoc false

  alias Omunculus.Model.OpenAI

  def new(spec) when is_map(spec) do
    inner = OpenAI.new(spec["params"])

    fn prompt, tools, call, record, delta, execution ->
      case Process.get(:omunculus_bench) do
        {parent, agent} ->
          send(parent, {:resident, agent, byte_size(Omunculus.Prompt.text(prompt))})

        nil ->
          :ok
      end

      inner.(prompt, tools, call, record, delta, execution)
    end
  end
end
