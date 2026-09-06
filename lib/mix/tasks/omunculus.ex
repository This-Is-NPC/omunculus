defmodule Mix.Tasks.Omunculus do
  @moduledoc "Run the omunculus CLI from Mix (`mix omunculus run …`)."
  use Mix.Task

  @shortdoc "Run the omunculus CLI"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    :erlang.halt(Omunculus.CLI.dispatch(args))
  end
end
