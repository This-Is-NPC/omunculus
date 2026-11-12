defmodule Omunculus.Tools.PushArtifacts do
  @moduledoc """
  Builtin `push_artifacts` tool: uploads the artifact versions of the run's
  conversation to the `[settings.s3]` bucket (`Omunculus.Artifacts.Sync`). What the
  bucket already holds is skipped, so a call may repeat. `name` keeps one
  artifact.
  """

  alias Omunculus.{Config, Tools.Args, Tools.Out}
  alias Omunculus.Artifacts.{S3, Sync}

  @spec run(map) :: map
  def run(%{args: args, view: view, config_path: config_path}) do
    versions = view["artifacts"] || []
    name = Args.present(args, "name")

    with {:ok, config} <- Config.load(config_path),
         {:ok, settings} <- S3.parse(view["s3"], config.auth.providers),
         id when is_binary(id) <-
           conversation_id(view) || {:error, "this run has no conversation"},
         {:ok, count} <-
           Sync.push(
             config,
             settings,
             id,
             Enum.filter(versions, &(is_nil(name) or &1["name"] == name))
           ) do
      Out.ok("pushed #{count.pushed} objects, #{count.present} already in the bucket")
    else
      {:error, message} when is_binary(message) -> Out.fail(message)
      {:error, reason} -> Out.fail(Out.failure(reason))
    end
  end

  defp conversation_id(%{"run" => [%{conversation_id: id} | _]}), do: id
  defp conversation_id(_view), do: nil
end
