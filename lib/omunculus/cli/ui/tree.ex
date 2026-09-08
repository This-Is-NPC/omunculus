defmodule Omunculus.CLI.UI.Tree do
  @behaviour Omunculus.CLI.UI
  @impl true
  def init(ctx),
    do: {nil, ["┌── #{ctx.mode} · #{ctx.path} · tree (chronological, indented by depth)"]}

  @impl true
  def event(item, state) do
    indent = String.duplicate("│  ", item.depth)
    edge = if item.kind == :end, do: "└─ ", else: "├─ "
    identity = if item.kind == :event, do: "[#{item.run_id || "session"}] ", else: ""

    {state,
     [indent <> edge <> identity <> item.title] ++ Enum.map(item.lines, &(indent <> "│  " <> &1))}
  end

  @impl true
  def finish(state), do: {state, []}
end
