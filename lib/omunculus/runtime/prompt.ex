defmodule Omunculus.Runtime.Prompt do
  @moduledoc "Configurable role, position and Run context around the harness protocol."

  def compose(ctx, name, role, instructions) do
    kind = ctx[:kind] || "worker"
    reason = ctx[:reason] || "initial"
    layers = get_in(ctx, [:config, :prompts]) || %{}

    position =
      if ctx.depth == 0,
        do: "You are the session's entry point; route work according to your role.",
        else: "Report to your runtime parent. Your comment is handed to the next Run."

    capability =
      cond do
        kind == "reviewer" ->
          "Execute the configured review gate. Inspect existing evidence against the criteria; report the verdict without repeating implementation effects."

        kind in ["concierge", "supervisor"] ->
          "Coordinate and review. Your own tools do not describe your children's tools. Use default delegation when appropriate; omit unknown agent/team selectors."

        true ->
          "Execute within your exposed tools and workspace. Preserve confirmed effects and report evidence."
      end

    phase =
      case reason do
        "assessment" ->
          "Assess the child delivery in your configured role. Your completed flag approves the TARGET stage for the harness to advance. This coordination decision does not activate a review gate."

        "step" ->
          "Execute the next configured stage using the responsible comment and existing evidence."

        "break" ->
          "Review escalated work. Your completion flag evaluates the TARGET work. You may recognize existing effects without reexecution."

        "retry" ->
          "Continue unfinished work using the previous comment and checkpoint. Do not repeat confirmed effects."

        "continuation" ->
          "Delivered child results have already been approved. Consolidate their evidence for your own current stage. Delegate additional work only for an identified unmet requirement; do not repeat approved effects."

        _ ->
          "Begin the assigned work. State constraints and expected evidence when delegating."
      end

    """
    You are #{name}. Kind: #{kind}. Depth: #{ctx.depth}/#{ctx.max_depth}.
    Workspace: #{ctx[:workspace] || ctx[:workspace_id] || "session"}. Run reason: #{reason}.
    #{if ctx[:assessment], do: "Assessing a child delivery; preserve your configured agent role.", else: stage_context(ctx)}
    The parent evaluates quality; the runtime executes the protocol and enforces tool authority.
    Use only exposed tools. Never invent effects, evidence, agent names or team names.
    Tool names are not agent names. Requests end this Run; do not poll waiting for responses.
    Configured agent: #{role || "Execute the assigned task."}
    #{get_in(layers, ["depth", to_string(ctx.depth)]) || position}
    #{get_in(layers, ["kind", kind]) || capability}
    #{get_in(layers, ["reason", reason]) || phase}
    #{profile(instructions, ctx, kind)}
    #{Omunculus.Runtime.Report.instruction()}
    """
  end

  defp stage_context(ctx) do
    steps = (ctx[:flow] || %{})["steps"] || []
    stage = Enum.find(steps, &(&1["name"] == ctx[:stage])) || List.first(steps)

    if stage,
      do: "Work stage: #{stage["name"]}. Stage instructions: #{stage["instructions"]}",
      else: "No staged workflow. Responsible approval completes the work item."
  end

  defp profile(text, ctx, kind) when is_binary(text) and text != "" do
    staged? = (ctx[:flow] || %{})["steps"] not in [nil, []]

    if staged? || ctx[:assessment] || kind in ["reviewer", "concierge", "supervisor"] do
      """
      Reference criteria for the original task (not execution instructions for this Run):
      <task_criteria>#{text}</task_criteria>
      Evaluate existing evidence or convey these criteria when delegating unfinished work.
      Follow your current role and stage instructions. The reference criteria are not an additional procedure to execute.
      """
    else
      "Task profile: #{text}"
    end
  end

  defp profile(_, _, _), do: ""
end
