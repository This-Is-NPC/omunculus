defmodule Omunculus.Tools.PutArtifact do
  @moduledoc """
  Builtin `put_artifact` tool: writes the next version of an artifact of
  the run's conversation (`docs/design.md §10`). The content is `data`, a
  JSON object kept as `application/json`, or `content` text of a
  `media_type`. The store keeps it and numbers the version.
  """

  alias Omunculus.Artifacts
  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, view: view}) do
    with nil <- Args.missing(args, ~w(name kind)),
         {:ok, media_type, content} <- content(args) do
      body =
        %{"name" => args["name"], "kind" => args["kind"], "media_type" => media_type}
        |> Map.put("content", content)
        |> Args.put_present("note", args)

      version = Artifacts.next(args["name"], view["artifacts"] || [])
      Out.ok("put #{args["name"]} version #{version}", [%{"type" => "artifact", "body" => body}])
    else
      message when is_binary(message) -> Out.fail(message)
      {:error, message} -> Out.fail(message)
    end
  end

  defp content(%{"data" => data} = args) when is_map(data) do
    if Map.has_key?(args, "content") or Map.has_key?(args, "media_type"),
      do: {:error, "data is the whole content: give no content or media_type with it"},
      else: {:ok, "application/json", Jason.encode!(data, pretty: true)}
  end

  defp content(%{"data" => _data}), do: {:error, "data must be an object"}

  defp content(args) do
    case Args.missing(args, ~w(content media_type)) do
      nil -> {:ok, args["media_type"], args["content"]}
      message -> {:error, "give data, or content with its media_type (#{message})"}
    end
  end
end
