defmodule Omunculus.Tools.Counter do
  @moduledoc false
  @behaviour Omunculus.Tool

  alias Omunculus.Tool.Context

  @impl true
  def name, do: "counter"

  @impl true
  def schema do
    %{
      "name" => "counter",
      "description" =>
        "Increment a harness-managed counter by the configured amount. A new work item starts at zero. Checkpoints preserve the current value across retries and stages of that work item. Every call mutates the counter; this is not a read or verification tool. Each call returns the new value. Use this tool when the user asks you to count incrementally.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{},
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def call(_args, context) do
    options = Context.tool_options(context, name())
    increment = options[:increment] || options["increment"] || 1
    state = Context.tool_state(context, name(), %{value: 0, calls: 0})
    value = state.value + increment
    state = %{value: value, calls: state.calls + 1, increment: increment}
    context = Context.put_tool_state(context, name(), state)
    {:ok, "Counter value: #{value}", context}
  end
end
