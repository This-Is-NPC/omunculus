defmodule Mix.Tasks.Omunculus.Presets do
  @moduledoc """
  Prints the directory of package presets.
  """

  use Mix.Task

  @shortdoc "Prints the package presets directory"

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")
    IO.puts(Application.app_dir(:omunculus, "priv/presets"))
  end
end
