defmodule Omunculus.Tools.Delegate do
  @moduledoc """
  Builtin `delegate` tool, the step `work` chains per item: creates a
  child work with a `title`, a `goal`, an optional `agent` or `workflow`
  and an optional `workspace` name, and hands it below. The parent waits for all
  its children.
  """

  alias Omunculus.Tools.{Args, Out}

  @required ~w(title goal)

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.missing(args, @required) do
      nil ->
        body =
          %{"title" => args["title"], "goal" => args["goal"]}
          |> Args.put_present("agent", args)
          |> Args.put_present("workflow", args)
          |> Args.put_present("workspace", args)

        Out.ok("", [%{"type" => "delegate", "body" => body}])

      message ->
        Out.fail(message)
    end
  end
end
