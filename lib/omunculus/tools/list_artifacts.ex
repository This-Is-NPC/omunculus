defmodule Omunculus.Tools.ListArtifacts do
  @moduledoc """
  Builtin `list_artifacts` tool: the artifacts of the run's conversation
  (the `artifacts` view), each with its kind and its versions, newest last.
  A `kind` argument keeps only the artifacts of that kind.
  """

  alias Omunculus.Artifacts
  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, view: view}) do
    kind = Args.present(args, "kind")

    artifacts =
      (view["artifacts"] || [])
      |> Artifacts.group()
      |> Enum.filter(&(is_nil(kind) or &1["kind"] == kind))

    case artifacts do
      [] -> Out.ok("no artifacts")
      _artifacts -> Out.ok(Enum.map_join(artifacts, "\n", &line/1))
    end
  end

  defp line(%{"name" => name, "kind" => kind, "versions" => versions}) do
    "- #{name} (#{kind}): " <> Enum.map_join(versions, ", ", &version/1)
  end

  defp version(version) do
    "v#{version["version"]} #{version["media_type"]} #{version["bytes"]} bytes by #{version["by"]}" <>
      if(version["note"], do: " (#{version["note"]})", else: "")
  end
end
