defmodule Omunculus.Tools.PutArtifact do
  @moduledoc """
  Builtin `put_artifact` tool: writes the next version of an artifact of
  the run's conversation (`docs/design.md §10`). The content is `data`, a
  JSON object kept as `application/json`, or `content` text of a
  `media_type`. With `base`, the number of the version it builds on (0 for
  none), the write is refused when another version came since. The store
  keeps it and numbers the version, unless the content equals the latest
  version's, which then stands.
  """

  alias Omunculus.{Artifacts, Config}
  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, view: view, config_path: config_path}) do
    versions = view["artifacts"] || []

    with nil <- Args.missing(args, ~w(name kind)),
         {:ok, media_type, content} <- content(args),
         {:ok, base} <- base(args),
         {:ok, config} <- Config.load(config_path),
         :ok <-
           Artifacts.check(
             config.store,
             versions,
             args["name"],
             args["kind"],
             media_type,
             byte_size(content),
             base
           ) do
      body =
        %{"name" => args["name"], "kind" => args["kind"], "media_type" => media_type}
        |> Map.put("content", content)
        |> Args.put_present("note", args)
        |> then(&if base, do: Map.put(&1, "base", base), else: &1)

      case Artifacts.unchanged(versions, args["name"], media_type, content) do
        %{"version" => version} ->
          Out.ok("#{args["name"]} version #{version} already holds this content", [])

        nil ->
          version = Artifacts.next(args["name"], versions)

          Out.ok("put #{args["name"]} version #{version}", [
            %{"type" => "artifact", "body" => body}
          ])
      end
    else
      message when is_binary(message) -> Out.fail(message)
      {:error, message} when is_binary(message) -> Out.fail(message)
      {:error, reason} -> Out.fail(Out.failure(reason))
    end
  end

  defp base(%{"base" => base}) when is_integer(base) and base >= 0, do: {:ok, base}
  defp base(%{"base" => _invalid}), do: {:error, "base must be a version number, or 0"}
  defp base(_args), do: {:ok, nil}

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
