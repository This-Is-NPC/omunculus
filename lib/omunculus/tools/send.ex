defmodule Omunculus.Tools.Send do
  @moduledoc """
  Builtin `send` tool, per spec §8.5: delivers a message as a `prompt` emit.
  """

  @spec run(map) :: map
  def run(%{args: %{"message" => message}}) when is_binary(message) and message != "" do
    %{
      "ok" => true,
      "output" => "",
      "emit" => [%{"type" => "prompt", "body" => %{"message" => message}}]
    }
  end

  def run(_input) do
    %{"ok" => false, "output" => "message required", "emit" => []}
  end
end
