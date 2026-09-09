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
        "Increment a harness-managed counter by the configured amount. The resource and its initial value are supplied by the scenario. A shared resource preserves effects across Work Items; a new delegation does not reset it. Every call mutates the counter; this is not a read or verification tool. Each call returns the new value. Use this tool when the user asks you to count incrementally.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{},
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def call(args, context), do: change(args, context, name(), 1)

  def change(args, context, tool, direction) when args == %{} do
    options = Context.tool_options(context, "counter")
    increment = direction * (options[:increment] || options["increment"] || 1)

    update = fn state ->
      %{value: state.value + increment, calls: state.calls + 1, increment: increment}
    end

    state =
      case options[:resource] do
        nil ->
          update.(Context.tool_state(context, "counter", %{value: 0, calls: 0}))

        resource ->
          Agent.get_and_update(resource, fn old ->
            new = update.(old)
            {new, new}
          end)
      end

    context =
      context |> Context.put_tool_state("counter", state) |> Context.put_tool_state(tool, state)

    {:ok, "Counter value: #{state.value}", context}
  end

  def change(_args, context, _tool, _direction), do: {:error, :invalid_arguments, context}
end
