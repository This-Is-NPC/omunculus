defmodule Omunculus.Tools.GetArtifact do
  @moduledoc """
  Builtin `get_artifact` tool: the content of a version of an artifact of
  the run's conversation (the `artifacts` view), the latest unless
  `version` names one. A version that is not text is refused with its size.
  """

  alias Omunculus.{Artifacts, Config}
  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, view: view, config_path: config_path}) do
    with nil <- Args.missing(args, ~w(name)),
         {:ok, number} <- Args.count(args, "version"),
         %{} = version <-
           Artifacts.find(view["artifacts"] || [], args["name"], number) || :unknown,
         {:ok, config} <- Config.load(config_path),
         {:ok, content} <- Artifacts.read(config.store, version) do
      if String.valid?(content),
        do: Out.ok(content),
        else: Out.fail(Out.not_text(args["name"], byte_size(content)))
    else
      :unknown -> Out.fail("no such version of #{args["name"]} in this conversation")
      message when is_binary(message) -> Out.fail(message)
      {:error, message} when is_binary(message) -> Out.fail(message)
      {:error, reason} -> Out.fail(Out.failure(reason))
    end
  end
end
