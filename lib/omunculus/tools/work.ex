defmodule Omunculus.Tools.Work do
  @moduledoc """
  Builtin `work` tool, per spec §8.5 and §9.1: creates or updates a work
  and writes its `title`, and an optional `workspace` name, as a `work`
  emit. It does not name stage, agent or model.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: %{"title" => title} = args}) when is_binary(title) and title != "" do
    body =
      %{"title" => title}
      |> Args.put_present("work_id", args)
      |> Args.put_present("parent_id", args)
      |> Args.put_present("workspace", args)

    Out.ok("", [%{"type" => "work", "body" => body}])
  end

  def run(_input) do
    Out.fail("title required")
  end
end
