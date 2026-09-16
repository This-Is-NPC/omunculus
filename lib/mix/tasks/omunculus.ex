defmodule Mix.Tasks.Omunculus do
  @moduledoc """
  Dispatches a tool by name through `Omunculus.CLI.main/1`.
  """

  use Mix.Task

  @shortdoc "Dispatches a tool by name"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    Omunculus.CLI.main(argv)
  end
end
