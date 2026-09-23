defmodule Omunculus.Tools.Send do
  @moduledoc """
  Builtin `send` tool, per spec §8.5: delivers a message, aimed at an
  existing work when `work_id` is given, as a `prompt` emit.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.fetch(args, "message") do
      {:ok, message} ->
        body = Args.put_present(%{"message" => message}, "work_id", args)
        Out.ok("", [%{"type" => "prompt", "body" => body}])

      {:error, error} ->
        Out.fail(error)
    end
  end
end
