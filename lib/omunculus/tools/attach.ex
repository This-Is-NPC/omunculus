defmodule Omunculus.Tools.Attach do
  @moduledoc """
  Builtin `attach` tool: attaches a file to the run's conversation, with an
  optional `note`: a file under the run's roots as it is now, read through
  the same checks as `read` and kept by `Omunculus.Attachments` with the
  media type its name suggests, or by reference a version of an artifact
  (the `artifacts` view), the latest unless `version` names one, which is
  exactly that file, which `name` may show under another file name. Either is emitted as an `attach`.
  """

  alias Omunculus.{Artifacts, Attachments, Config}
  alias Omunculus.Execution.Policy
  alias Omunculus.Tools.{Args, Out}

  @spec run(map, Policy.t()) :: map
  def run(%{args: args} = input, %Policy{} = policy) do
    with {:ok, meta, default_note} <- file(input, policy) do
      body =
        %{"attachments" => [meta]}
        |> Map.put("note", Args.present(args, "note") || default_note)
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      Out.ok("attached #{meta["name"]} (#{meta["bytes"]} bytes)", [
        %{"type" => "attach", "body" => body}
      ])
    else
      {:error, message} when is_binary(message) -> Out.fail(message)
      {:error, reason} -> Out.fail(Out.failure(reason))
    end
  end

  defp file(%{args: %{"path" => _, "artifact" => _}}, _policy),
    do: {:error, "give path or artifact, not both"}

  defp file(%{args: %{"artifact" => name} = args, view: view}, _policy) do
    with {:ok, number} <- Args.count(args, "version"),
         %{} = version <- Artifacts.find(view["artifacts"] || [], name, number) || :unknown do
      meta = Map.take(version, ~w(name media_type bytes sha256))
      shown = Args.present(args, "name") || name
      {:ok, %{meta | "name" => shown}, "#{name} version #{version["version"]}"}
    else
      :unknown -> {:error, "no such version of #{name} in this conversation"}
      error -> error
    end
  end

  defp file(%{args: args, roots: roots, config_path: config_path} = input, policy) do
    permissions = Omunculus.Tools.Path.permissions(input)

    with nil <- Args.missing(args, ~w(path)),
         {:ok, absolute} <-
           Omunculus.Tools.Path.resolve(roots, args["path"], permissions, policy),
         {:ok, content} <- read(absolute, args["path"]),
         {:ok, config} <- Config.load(config_path),
         name = Path.basename(absolute),
         {:ok, meta} <- Attachments.put(config.store, name, MIME.from_path(name), content) do
      {:ok, meta, nil}
    else
      "path required" -> {:error, "give path, or artifact"}
      other -> other
    end
  end

  defp read(path, named) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _reason} -> {:error, "no such file: #{named}"}
    end
  end
end
