defmodule Omunculus.Tools.Work do
  @moduledoc """
  Builtin `work` tool, per spec §8.5: creates or updates a work and writes
  its `title` as a `work` emit. It does not name stage, agent or model.
  """

  alias Omunculus.Tools.Args

  @spec run(map) :: map
  def run(%{args: %{"title" => title} = args}) when is_binary(title) and title != "" do
    body =
      %{"title" => title}
      |> Args.put_present("work_id", args)
      |> Args.put_present("parent_id", args)

    %{"ok" => true, "output" => "", "emit" => [%{"type" => "work", "body" => body}]}
  end

  def run(_input) do
    %{"ok" => false, "output" => "title required", "emit" => []}
  end
end
