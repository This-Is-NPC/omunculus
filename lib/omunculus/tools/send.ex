defmodule Omunculus.Tools.Send do
  @moduledoc """
  Builtin `send` tool, per spec §8.5: delivers a message, aimed at an
  existing work when `work_id` is given, or else at the `agent` of depth 0
  it names, as a `prompt` emit.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.fetch(args, "message") do
      {:ok, message} ->
        body =
          %{"message" => message}
          |> Args.put_present("work_id", args)
          |> Args.put_present("agent", args)

        Out.ok("", [%{"type" => "prompt", "body" => body}])

      {:error, error} ->
        Out.fail(error)
    end
  end
end
