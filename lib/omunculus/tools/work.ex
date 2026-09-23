defmodule Omunculus.Tools.Work do
  @moduledoc """
  Builtin `work` tool, per spec §8.5 and §9.1: creates or updates a work
  and writes its `title`, its `goal`, and an optional `workspace` name, as
  a `work` emit. It does not name stage, agent or model.
  """

  alias Omunculus.Tools.{Args, Out}

  @required ~w(title goal)

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.missing(args, @required) do
      nil ->
        body =
          %{"title" => args["title"], "goal" => args["goal"]}
          |> Args.put_present("work_id", args)
          |> Args.put_present("parent_id", args)
          |> Args.put_present("workspace", args)

        Out.ok("", [%{"type" => "work", "body" => body}])

      message ->
        Out.fail(message)
    end
  end
end
