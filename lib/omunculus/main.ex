defmodule Omunculus.Main do
  @moduledoc """
  The entry of the `omunculus` binary once the application runs: `mix
  omunculus` in a checkout and the release's `eval` after `bin/omunculus`
  call it, so both dispatch the same way.
  """

  @spec run([String.t()]) :: :ok
  def run(argv) do
    Application.put_env(:omunculus, :package_tools, Application.app_dir(:omunculus, "priv/tools"))

    case argv do
      ["serve" | rest] -> Omunculus.Server.main(rest)
      ["socket" | rest] -> Omunculus.Server.Locate.main(rest)
      _ -> Omunculus.CLI.main(argv)
    end
  end
end
