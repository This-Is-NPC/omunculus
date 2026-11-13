defmodule Omunculus.Tools.Update do
  @moduledoc """
  `update` tool: compares the running version with the latest GitHub
  release (one GET, no telemetry), downloads its packages, checks them
  against `SHA256SUMS` and installs them with `pacman -U --noconfirm` run through `pkexec`, or
  through `sudo` in a terminal. The
  release API is `:omunculus, :release_api`, which tests point at a stub.
  """

  alias Omunculus.Tools.{Args, Out}

  @core ~r/^omunculus-\d.*-x86_64\.pkg\.tar\.zst$/
  @apps ~r/^omunculus-apps-.*-any\.pkg\.tar\.zst$/
  @pacman ["pacman", "-U", "--noconfirm"]
  @prompt "[sudo] password to install omunculus: "
  @refused "the password was not given; nothing was installed"
  @no_elevator "pkexec is not installed, and there is no terminal for sudo to ask for the password; " <>
                 "install polkit, or run omunculus update in a terminal"
  @preload [:omunculus, :elixir, :logger, :stdlib, :kernel]
  @api "https://api.github.com/repos/This-Is-NPC/omunculus/releases/latest"

  @spec run(map) :: map
  def run(%{args: args}) do
    running = Omunculus.Tools.Version.current()

    with {:ok, release} <- latest(running),
         {:ok, latest} <- release_version(release) do
      if Version.compare(latest, running) == :gt do
        update(release, latest, running, Args.flag?(args, "check"))
      else
        Out.ok("omunculus #{running} is up to date.")
      end
    else
      {:error, message} -> Out.fail(message)
    end
  end

  defp update(%{"tag_name" => tag} = release, latest, running, check?) do
    case packages(release) do
      {:ok, assets} when check? ->
        Out.ok(
          "omunculus #{latest} is available (installed #{running}). " <>
            "`omunculus update` installs #{Enum.map_join(assets, ", ", & &1["name"])}."
        )

      {:ok, assets} ->
        install(release, assets, latest)

      :error when check? ->
        Out.ok(
          "omunculus #{latest} is available (installed #{running}), but it has no package yet."
        )

      :error ->
        Out.fail("#{tag} is out but carries no omunculus package yet; nothing was installed")
    end
  end

  defp latest(running) do
    case Req.get(api(),
           headers: [
             {"user-agent", "omunculus/#{running}"},
             {"accept", "application/vnd.github+json"}
           ],
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"tag_name" => _tag} = release}} -> {:ok, release}
      {:ok, %{status: status}} -> {:error, "the release server answered #{status}"}
      {:error, error} -> {:error, "cannot reach the release server: #{Exception.message(error)}"}
    end
  end

  defp release_version(%{"tag_name" => tag}) do
    case tag |> String.trim_leading("v") |> Version.parse() do
      {:ok, version} -> {:ok, version}
      :error -> {:error, "the latest release has no version: #{tag}"}
    end
  end

  # The core package, and the apps one only when it is installed.
  defp packages(%{"assets" => assets}) do
    with {:ok, core} <- find(assets, @core) do
      case find(assets, @apps) do
        {:ok, apps} -> {:ok, [core | if(installed?("omunculus-apps"), do: [apps], else: [])]}
        :error -> {:ok, [core]}
      end
    end
  end

  defp find(assets, pattern) do
    case Enum.find(assets, &Regex.match?(pattern, &1["name"])) do
      nil -> :error
      asset -> {:ok, asset}
    end
  end

  defp installed?(package), do: match?({_, 0}, runner().run("pacman", ["-Q", package]))

  defp install(release, assets, latest) do
    dir = Path.join(System.tmp_dir!(), "omunculus-update-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      with {:ok, elevator} <- elevator(),
           :ok <- preload(),
           {:ok, sums} <- sums(release, dir),
           {:ok, files} <- download(assets, sums, dir),
           :ok <- pacman(elevator, files) do
        message = "omunculus #{latest} installed.\n" <> restart()
        runner().finish(message)
        Out.ok(message)
      else
        {:error, message} -> Out.fail(message)
      end
    after
      File.rm_rf!(dir)
    end
  end

  defp sums(%{"assets" => assets}, dir) do
    with {:ok, asset} <- find(assets, ~r/^SHA256SUMS$/) |> checksums(),
         {:ok, path} <- fetch(asset, dir),
         {:ok, text} <- File.read(path) do
      sums =
        for line <- String.split(text, "\n", trim: true),
            [hash, name] <- [String.split(line, ~r/\s+\*?/, parts: 2)],
            into: %{},
            do: {name, String.downcase(hash)}

      {:ok, sums}
    end
  end

  defp checksums({:ok, _asset} = found), do: found
  defp checksums(:error), do: {:error, "the release carries no SHA256SUMS; nothing was installed"}

  defp download(assets, sums, dir) do
    Enum.reduce_while(assets, {:ok, []}, fn %{"name" => name} = asset, {:ok, files} ->
      with {:ok, expected} <- Map.fetch(sums, name) |> listed(name),
           {:ok, path} <- fetch(asset, dir),
           :ok <- verify(path, expected, name) do
        {:cont, {:ok, files ++ [path]}}
      else
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp listed({:ok, hash}, _name), do: {:ok, hash}
  defp listed(:error, name), do: {:error, "SHA256SUMS does not list #{name}"}

  defp fetch(%{"name" => name, "browser_download_url" => url}, dir) do
    path = Path.join(dir, name)

    case Req.get(url, into: File.stream!(path), retry: false, redirect_log_level: false) do
      {:ok, %{status: 200}} -> {:ok, path}
      {:ok, %{status: status}} -> {:error, "downloading #{name} answered #{status}"}
      {:error, error} -> {:error, "cannot download #{name}: #{Exception.message(error)}"}
    end
  end

  defp verify(path, expected, name) do
    actual =
      path
      |> File.stream!(65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual == expected,
      do: :ok,
      else: {:error, "#{name} does not match its checksum in SHA256SUMS; nothing was installed"}
  end

  # pacman replaces the files of this running program, so every module the rest
  # of the command can call is loaded first; `finish` then ends it at once.
  defp preload do
    for app <- @preload,
        module <- Application.spec(app, :modules) || [],
        do: Code.ensure_loaded!(module)

    :ok
  end

  # Chosen before anything is downloaded: pkexec asks for the password in its
  # own window; without it, sudo asks on the terminal there is.
  defp elevator do
    cond do
      runner().executable("pkexec") -> {:ok, :pkexec}
      runner().terminal() -> {:ok, :sudo}
      true -> {:error, @no_elevator}
    end
  end

  # Running `update` is the consent, so pacman never asks. sudo reads its password
  # on the terminal device (the runner's child has no controlling terminal) with
  # echo off, and pacman runs on the credentials that leaves.
  defp pacman(:pkexec, files), do: elevated("pkexec", @pacman ++ files)

  defp pacman(:sudo, files) do
    case runner().run_tty("sudo", ["-S", "-p", @prompt, "-v"], echo: false) do
      0 -> elevated("sudo", ["-n" | @pacman] ++ files)
      _ -> {:error, @refused}
    end
  end

  defp elevated(elevator, args) do
    case runner().run_tty(elevator, args, []) do
      0 -> :ok
      status when status in [126, 127] and elevator == "pkexec" -> {:error, @refused}
      status when status in 129..159 -> {:error, "pacman -U was stopped by a signal"}
      status -> {:error, "pacman -U failed with exit status #{status}"}
    end
  end

  defp restart do
    with {_, 0} <- runner().run("systemctl", ["--user", "is-active", "--quiet", "omunculus"]),
         {_, 0} <- runner().run("systemctl", ["--user", "restart", "omunculus"]) do
      "The user unit omunculus was restarted."
    else
      _ -> "The user unit omunculus is not running; nothing was restarted."
    end
  end

  defp api, do: Application.get_env(:omunculus, :release_api, @api)
  defp runner, do: Application.get_env(:omunculus, :runner, Omunculus.Runner)
end
