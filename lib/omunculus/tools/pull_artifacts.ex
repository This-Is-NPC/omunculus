defmodule Omunculus.Tools.PullArtifacts do
  @moduledoc """
  Builtin `pull_artifacts` tool: restores into the run's conversation the
  artifact versions the `[s3]` bucket holds for a conversation (this one,
  or `conversation`) that it lacks, as `artifact` actions
  (`Omunculus.Artifacts.Sync`), text and bytes alike. Rerunning restores
  nothing more. A version that does not follow the ones held is left out
  and named.
  """

  alias Omunculus.{Config, Tools.Args, Tools.Out}
  alias Omunculus.Artifacts.Sync

  @spec run(map) :: map
  def run(%{args: args, view: view, config_path: config_path}) do
    with {:ok, config} <- Config.load(config_path),
         %{} <- config.s3 || {:error, "no [s3] table in the config"},
         id when is_binary(id) <-
           Args.present(args, "conversation") || conversation_id(view) ||
             {:error, "this run has no conversation"},
         {:ok, %{emit: emit, skipped: skipped}} <- Sync.pull(config, id, view["artifacts"] || []) do
      Out.ok(summary(emit, skipped), emit)
    else
      {:error, message} when is_binary(message) -> Out.fail(message)
      {:error, reason} -> Out.fail(Out.failure(reason))
    end
  end

  defp summary(emit, skipped) do
    restored = "restored #{length(emit)} versions"

    case skipped do
      [] -> restored
      _skipped -> restored <> "; left out, out of order: " <> Enum.join(skipped, ", ")
    end
  end

  defp conversation_id(%{"run" => [%{conversation_id: id} | _]}), do: id
  defp conversation_id(_view), do: nil
end
