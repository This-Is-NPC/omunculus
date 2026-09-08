defmodule Omunculus.CLI.UI.Tree do
  @behaviour Omunculus.CLI.UI
  alias Omunculus.CLI.UI.Text
  @impl true
  def init(ctx),
    do:
      {ctx.width,
       Text.lines(
         "#{ctx.mode} · #{ctx.path} · tree (chronological, indented by depth)",
         ctx.width
       )}

  @impl true
  def event(item, width) do
    indent = String.duplicate("│  ", item.depth)
    edge = if item.kind == :end, do: "└─ ", else: "├─ "
    identity = if item.kind == :event, do: "[#{item.run_id || "session"}] ", else: ""

    {width,
     Text.lines(identity <> item.title, width, indent <> edge, indent <> "│  ") ++
       Enum.flat_map(item.lines, &Text.lines(&1, width, indent <> "│  "))}
  end

  @impl true
  def finish(state), do: {state, []}
end
