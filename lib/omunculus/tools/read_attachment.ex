defmodule Omunculus.Tools.ReadAttachment do
  @moduledoc """
  Builtin `read_attachment` tool: the content of a file attached in the
  run's conversation (the `attachments` view), named by its `sha256`, as
  `Omunculus.Attachments` keeps it. A file that is not text is refused
  with its size.
  """

  alias Omunculus.{Attachments, Config}
  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, view: view, config_path: config_path}) do
    attached = view["attachments"] || []

    with nil <- Args.missing(args, ~w(sha256)),
         %{} = file <- Enum.find(attached, &(&1["sha256"] == args["sha256"])) || :unknown,
         {:ok, config} <- Config.load(config_path),
         {:ok, path} <- Attachments.path(config.store, file["sha256"]),
         {:ok, content} <- File.read(path) do
      if String.valid?(content),
        do: Out.ok(content),
        else: Out.fail(Out.not_text(file["name"], byte_size(content)))
    else
      :unknown -> Out.fail("no file of sha256 #{args["sha256"]} is attached in this conversation")
      message when is_binary(message) -> Out.fail(message)
      {:error, reason} -> Out.fail(Out.failure(reason))
    end
  end
end
