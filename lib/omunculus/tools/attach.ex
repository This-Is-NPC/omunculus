defmodule Omunculus.Tools.Attach do
  @moduledoc """
  Builtin `attach` tool: attaches a file under the run's roots, as it is
  now, to the run's conversation, with an optional `note`. The file is
  read through the same checks as `read`, kept by `Omunculus.Attachments`
  with the media type its name suggests, and emitted as an `attach`.
  """

  alias Omunculus.{Attachments, Config}
  alias Omunculus.Execution.Policy
  alias Omunculus.Tools.{Args, Out}

  @spec run(map, Policy.t()) :: map
  def run(%{args: args, roots: roots, config_path: config_path} = input, %Policy{} = policy) do
    permissions = Omunculus.Tools.Path.permissions(input)

    with nil <- Args.missing(args, ~w(path)),
         {:ok, absolute} <-
           Omunculus.Tools.Path.resolve(roots, args["path"], permissions, policy),
         {:ok, content} <- read(absolute, args["path"]),
         {:ok, config} <- Config.load(config_path),
         name = Path.basename(absolute),
         {:ok, meta} <- Attachments.put(config.store, name, MIME.from_path(name), content) do
      body = %{"attachments" => [meta]} |> Args.put_present("note", args)
      Out.ok("attached #{name} (#{meta["bytes"]} bytes)", [%{"type" => "attach", "body" => body}])
    else
      message when is_binary(message) -> Out.fail(message)
      {:error, message} when is_binary(message) -> Out.fail(message)
      {:error, reason} -> Out.fail(Out.failure(reason))
    end
  end

  defp read(path, named) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _reason} -> {:error, "no such file: #{named}"}
    end
  end
end
