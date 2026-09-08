defmodule Omunculus.CLI.UI.Timeline do
  @behaviour Omunculus.CLI.UI
  alias Omunculus.CLI.UI.Text
  @impl true
  def init(ctx), do: {ctx.width, Text.lines("#{ctx.mode} · #{ctx.path} · timeline", ctx.width)}
  @impl true
  def event(item, width) do
    label = "#{item.timestamp} ##{item.sequence} [#{item.run_id || "session"}]"

    {width,
     Text.lines(label <> " " <> item.title, width, "├─ ", "│  ") ++
       Enum.flat_map(item.lines, &Text.lines(&1, width, "│  "))}
  end

  @impl true
  def finish(state), do: {state, []}
end
