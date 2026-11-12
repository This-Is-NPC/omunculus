defmodule Omunculus.Tools.Update do
  @moduledoc """
  `update` tool: compares the running version with the latest GitHub
  release (one GET, no telemetry), downloads its packages, checks them
  against `SHA256SUMS` and installs them with `sudo pacman -U`. The
  release API is `:omunculus, :release_api`, which tests point at a stub.
  """

  alias Omunculus.Tools.{Args, Out}

  @core ~r/^omunculus-\d.*-x86_64\.pkg\.tar\.zst$/
  @apps ~r/^omunculus-apps-.*-any\.pkg\.tar\.zst$/
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

  defp update(release, latest, running, check?) do
    with {:ok, assets} <- packages(release) do
      names = Enum.map(assets, & &1["name"])

      if check? do
        Out.ok(
          "omunculus #{latest} is available, you run #{running}. " <>
            "`omunculus update` installs #{Enum.join(names, ", ")}."
        )
      else
        install(release, assets, latest)
      end
    else
      {:error, message} -> Out.fail(message)
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
        {:error, _absent} -> {:ok, [core]}
      end
    end
  end

  defp find(assets, pattern) do
    case Enum.find(assets, &Regex.match?(pattern, &1["name"])) do
      nil -> {:error, "the latest release has no #{inspect(pattern.source)} package"}
      asset -> {:ok, asset}
    end
  end

  defp installed?(package), do: match?({_, 0}, runner().run("pacman", ["-Q", package]))

  defp install(release, assets, latest) do
    dir = Path.join(System.tmp_dir!(), "omunculus-update-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      with {:ok, sums} <- sums(release, dir),
           {:ok, files} <- download(assets, sums, dir),
           :ok <- pacman(files) do
        Out.ok("omunculus #{latest} installed.\n" <> restart())
      else
        {:error, message} -> Out.fail(message)
      end
    after
      File.rm_rf!(dir)
    end
  end

  defp sums(%{"assets" => assets}, dir) do
    with {:ok, asset} <- find(assets, ~r/^SHA256SUMS$/),
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

    case Req.get(url, into: File.stream!(path), retry: false) do
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

  defp pacman(files) do
    case runner().run_tty("sudo", ["pacman", "-U" | files]) do
      0 -> :ok
      status -> {:error, "sudo pacman -U failed with status #{status}; nothing was updated"}
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
