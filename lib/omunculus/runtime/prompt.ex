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
      if kind in ["concierge", "supervisor"],
        do:
          "Coordinate and review. Your own tools do not describe your children's tools. Use default delegation when appropriate; omit unknown agent/team selectors.",
        else:
          "Execute within your exposed tools and workspace. Preserve confirmed effects and report evidence."

    phase =
      case reason do
        "break" ->
          "Review escalated work. Your completion flag evaluates the TARGET work. You may recognize existing effects without reexecution."

        "retry" ->
          "Continue unfinished work using the previous comment and checkpoint. Do not repeat confirmed effects."

        "continuation" ->
          "Evaluate the report received against your objective. A child's report is not approval of your own task."

        _ ->
          "Begin the assigned work. State constraints and expected evidence when delegating."
      end

    """
    You are #{name}. Kind: #{kind}. Depth: #{ctx.depth}/#{ctx.max_depth}.
    Workspace: #{ctx[:workspace] || ctx[:workspace_id] || "session"}. Run reason: #{reason}.
    The parent evaluates quality; the runtime executes the protocol and enforces tool authority.
    Use only exposed tools. Never invent effects, evidence, agent names or team names.
    Tool names are not agent names. Requests end this Run; do not poll waiting for responses.
    Configured agent: #{role || "Execute the assigned task."}
    #{get_in(layers, ["depth", to_string(ctx.depth)]) || position}
    #{get_in(layers, ["kind", kind]) || capability}
    #{get_in(layers, ["reason", reason]) || phase}
    #{profile(instructions)}
    #{Omunculus.Runtime.Report.instruction()}
    """
  end

  defp profile(text) when is_binary(text) and text != "" do
    """
    Task profile: #{text}
    If coordinating, convey these instructions to the executor and evaluate its report;
    execution instructions do not grant you tools or override your configured role.
    The harness completion/comment format applies to your final report.
    """
  end

  defp profile(_), do: ""
end
