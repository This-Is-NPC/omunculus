defmodule Omunculus.CLI.UI.Blocks do
  @behaviour Omunculus.CLI.UI
  @impl true
  def init(ctx), do: {%{current: nil}, ["┌── #{ctx.mode} · #{ctx.path} · blocks"]}
  @impl true
  def event(item, state) do
    resume =
      if item.run_id && state.current != item.run_id && item.kind != :start,
        do: ["", "↳ RUN #{item.run_id} · continuing display"],
        else: []

    prefix =
      case item.kind do
        :start -> "┌── "
        :end -> "└── "
        _ -> "├── "
      end

    lines = resume ++ [prefix <> item.title] ++ Enum.map(item.lines, &("│   " <> &1))

    lines =
      if item.kind == :end,
        do: resume ++ Enum.map(item.lines, &("│   " <> &1)) ++ [prefix <> item.title, ""],
        else: lines

    {%{state | current: item.run_id}, lines}
  end

  @impl true
  def finish(state), do: {state, []}
end
