defmodule Omunculus.CLI.UI.Timeline do
  @behaviour Omunculus.CLI.UI
  @impl true
  def init(ctx), do: {nil, ["┌── #{ctx.mode} · #{ctx.path} · timeline"]}
  @impl true
  def event(item, state) do
    label = "#{item.timestamp} ##{item.sequence} [#{item.run_id || "session"}]"
    {state, [label <> " " <> item.title] ++ Enum.map(item.lines, &("  │ " <> &1))}
  end

  @impl true
  def finish(state), do: {state, []}
end
