defmodule Omunculus.Tools.Send do
  @moduledoc """
  Builtin `send` tool, per spec §8.5: delivers a message, aimed at an
  existing work when `work_id` is given, as a `prompt` emit.
  """

  alias Omunculus.Tools.Args

  @spec run(map) :: map
  def run(%{args: %{"message" => message} = args}) when is_binary(message) and message != "" do
    body = Args.put_present(%{"message" => message}, "work_id", args)

    %{"ok" => true, "output" => "", "emit" => [%{"type" => "prompt", "body" => body}]}
  end

  def run(_input) do
    %{"ok" => false, "output" => "message required", "emit" => []}
  end
end
