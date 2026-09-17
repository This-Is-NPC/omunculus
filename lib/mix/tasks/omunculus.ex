defmodule Mix.Tasks.Omunculus do
  @moduledoc """
  Dispatches a tool by name through `Omunculus.CLI.main/1`.
  """

  use Mix.Task

  @shortdoc "Dispatches a tool by name"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    Application.put_env(:omunculus, :package_tools, Application.app_dir(:omunculus, "priv/tools"))
    Omunculus.CLI.main(argv)
  end
end
