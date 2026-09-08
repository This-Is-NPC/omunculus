defmodule Omunculus.CLI.UI.Blocks do
  @behaviour Omunculus.CLI.UI
  alias Omunculus.CLI.UI.Text
  @impl true
  def init(ctx),
    do:
      {%{current: nil, width: ctx.width},
       Text.lines("#{ctx.mode} · #{ctx.path} · blocks", ctx.width)}

  @impl true
  def event(item, state) do
    resume =
      if item.run_id && state.current != item.run_id && item.kind != :start,
        do: Text.lines("↳ RUN #{item.run_id} · continuing display", state.width),
        else: []

    title = Text.lines(item.title, state.width)
    content = Enum.flat_map(item.lines, &Text.lines(&1, state.width, "  "))
    separator = String.duplicate("─", state.width)

    lines =
      if item.kind == :end,
        do: resume ++ content ++ [separator] ++ title ++ [""],
        else: [separator] ++ resume ++ title ++ content

    {%{state | current: item.run_id}, lines}
  end

  @impl true
  def finish(state), do: {state, []}
end
