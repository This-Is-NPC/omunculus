defmodule Omunculus.Tools.Setup do
  @moduledoc """
  `setup` tool: writes the server registry `server.toml` under
  `$XDG_CONFIG_HOME/omunculus` when it is missing, enables and starts the
  user unit, and says what to do next. Rerunning keeps what exists.
  """

  alias Omunculus.Tools.Out

  @server """
  [server]
  max_concurrent = 8
  max_queue = 64
  queue_timeout_ms = 30000
  max_connections = 64
  """

  @unit ["--user", "enable", "--now", "omunculus"]

  @spec run(map) :: map
  def run(_input) do
    path = Path.join([config_home(), "omunculus", "server.toml"])

    with {:ok, written} <- write(path),
         :ok <- enable() do
      Out.ok(
        Enum.join([written, "The user unit omunculus is enabled and started.", next()], "\n")
      )
    else
      {:error, message} -> Out.fail(message)
    end
  end

  defp config_home do
    case System.get_env("XDG_CONFIG_HOME") do
      dir when is_binary(dir) and dir != "" -> dir
      _unset -> Path.join(System.user_home!(), ".config")
    end
  end

  defp write(path) do
    if File.exists?(path) do
      {:ok, "#{path} already exists; kept as it is."}
    else
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, @server) do
        {:ok, "Wrote #{path}:\n\n#{@server}"}
      else
        {:error, reason} ->
          {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
      end
    end
  end

  defp enable do
    case runner().run("systemctl", @unit) do
      {_output, 0} ->
        :ok

      {output, _status} ->
        {:error, "systemctl --user enable --now omunculus failed: #{String.trim(output)}"}
    end
  end

  defp next do
    """

    The server runs with no project yet. Start one in an empty folder, then
    register it with a `[projects.<id>]` table holding its `config` in that
    file and `systemctl --user restart omunculus`. The guide goes from there
    to a first message:
    https://github.com/This-Is-NPC/omunculus/blob/master/docs/how-to-start-a-project.md
    """
    |> String.trim_trailing()
  end

  defp runner, do: Application.get_env(:omunculus, :runner, Omunculus.Runner)
end
