defmodule Omunculus.ReleaseCommandsTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Omunculus.CLI
  alias Omunculus.Fixtures

  # Records every external command; `installed` answers `pacman -Q`.
  defmodule FakeRunner do
    def run(command, args) do
      Agent.update(__MODULE__, &[{command, args} | &1])

      case {command, args} do
        {"pacman", ["-Q", "omunculus-apps"]} -> {"", if(opt(:apps), do: 0, else: 1)}
        {"systemctl", ["--user", "is-active" | _]} -> {"", if(opt(:active), do: 0, else: 3)}
        _ -> {"", 0}
      end
    end

    def run_tty(command, args) do
      Agent.update(__MODULE__, &[{command, args} | &1])
      opt(:status) || 0
    end

    def tty?, do: opt(:tty)

    defp opt(key), do: Application.get_env(:omunculus, :fake_runner)[key]
    def log, do: Agent.get(__MODULE__, &Enum.reverse/1)
  end

  # Serves a latest release listing the assets and their bytes.
  defmodule Stub do
    @behaviour Plug
    def init(opts), do: opts

    def call(%{request_path: "/latest"} = conn, opts) do
      base = "http://127.0.0.1:#{opts.port.()}/files/"

      assets =
        for name <- Map.keys(opts.files),
            do: %{"name" => name, "browser_download_url" => base <> name}

      conn
      |> put_resp_header("x-agent", get_req_header(conn, "user-agent") |> hd())
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"tag_name" => opts.tag, "assets" => assets}))
    end

    def call(%{request_path: "/files/" <> name} = conn, opts),
      do: send_resp(conn, 200, Map.fetch!(opts.files, name))
  end

  # The running version and the next minor one, so the tests hold at any release.
  @installed Mix.Project.config()[:version]
  @next (fn v -> "#{v.major}.#{v.minor + 1}.0" end).(Version.parse!(@installed))
  @core "omunculus-#{@next}-1-x86_64.pkg.tar.zst"
  @apps "omunculus-apps-#{@next}-1-any.pkg.tar.zst"

  defp sha(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp serve(tag, sums_for \\ %{}, files \\ %{@core => "core bytes", @apps => "apps bytes"}) do
    sums =
      Enum.map_join(files, fn {name, data} ->
        "#{Map.get(sums_for, name, sha(data))}  #{name}\n"
      end)

    files = Map.put(files, "SHA256SUMS", sums)
    {:ok, agent} = Agent.start_link(fn -> nil end)
    opts = %{tag: tag, files: files, port: fn -> Agent.get(agent, & &1) end}

    {:ok, server} =
      Bandit.start_link(plug: {Stub, opts}, port: 0, ip: :loopback, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    Agent.update(agent, fn _ -> port end)
    Application.put_env(:omunculus, :release_api, "http://127.0.0.1:#{port}/latest")
  end

  setup do
    start_supervised!(%{
      id: FakeRunner,
      start: {Agent, :start_link, [fn -> [] end, [name: FakeRunner]]}
    })

    Application.put_env(:omunculus, :runner, FakeRunner)
    Application.put_env(:omunculus, :fake_runner, apps: false, active: true, tty: true, status: 0)

    on_exit(fn ->
      Enum.each([:runner, :fake_runner, :release_api], &Application.delete_env(:omunculus, &1))
    end)

    %{dir: Fixtures.tmp_dir()}
  end

  defp sudo_files, do: for({"sudo", ["pacman", "-U" | files]} <- FakeRunner.log(), do: files)
  defp pacman_args, do: for({"sudo", ["pacman", "-U" | args]} <- FakeRunner.log(), do: args)

  defp fake(opts),
    do: Application.put_env(:omunculus, :fake_runner, Keyword.merge(fake_opts(), opts))

  defp fake_opts, do: Application.get_env(:omunculus, :fake_runner)

  test "version prints the running version", %{dir: dir} do
    assert {:ok, version} = CLI.run(["version"], dir)
    assert version == to_string(Application.spec(:omunculus, :vsn))
  end

  test "update says it is up to date", %{dir: dir} do
    serve("v0.0.1")
    assert {:ok, "omunculus " <> rest} = CLI.run(["update"], dir)
    assert rest =~ "is up to date"
    assert FakeRunner.log() == []
  end

  test "update installs the core package alone when apps are not installed", %{dir: dir} do
    serve("v#{@next}")
    assert {:ok, output} = CLI.run(["update"], dir)
    assert output =~ "#{@next} installed"
    assert [[file]] = sudo_files()
    assert Path.basename(file) == @core
    assert {"systemctl", ["--user", "restart", "omunculus"]} in FakeRunner.log()
  end

  test "update installs both packages when apps are installed and skips a stopped unit", %{
    dir: dir
  } do
    fake(apps: true, active: false)
    serve("v#{@next}")
    assert {:ok, output} = CLI.run(["update"], dir)
    assert output =~ "nothing was restarted"
    assert [files] = sudo_files()
    assert Enum.map(files, &Path.basename/1) == [@core, @apps]
    refute {"systemctl", ["--user", "restart", "omunculus"]} in FakeRunner.log()
  end

  test "update lets pacman ask on the terminal when there is one", %{dir: dir} do
    serve("v#{@next}")
    assert {:ok, _output} = CLI.run(["update"], dir)
    assert [[file]] = pacman_args()
    assert Path.basename(file) == @core
  end

  test "update passes --noconfirm when there is no terminal", %{dir: dir} do
    fake(tty: false)
    serve("v#{@next}")
    assert {:ok, _output} = CLI.run(["update"], dir)
    assert [["--noconfirm", file]] = pacman_args()
    assert Path.basename(file) == @core
  end

  test "update fails when pacman fails", %{dir: dir} do
    fake(status: 1)
    serve("v#{@next}")
    assert {:error, reason} = CLI.run(["update"], dir)
    assert CLI.message(reason) == "sudo pacman -U failed with status 1; nothing was updated"
  end

  test "update refuses a package whose checksum differs", %{dir: dir} do
    serve("v#{@next}", %{@core => String.duplicate("0", 64)})
    assert {:error, reason} = CLI.run(["update"], dir)
    assert CLI.message(reason) =~ "#{@core} does not match its checksum"
    assert sudo_files() == []
  end

  test "update --check reports and installs nothing", %{dir: dir} do
    serve("v#{@next}")
    assert {:ok, output} = CLI.run(["update", "--check"], dir)
    assert output =~ "#{@next} is available (installed #{@installed})"
    assert output =~ @core
    refute output =~ @apps
    assert sudo_files() == []
  end

  test "a release with no package is said in words, and checked without failing", %{dir: dir} do
    serve("v#{@next}", %{}, %{"notes.txt" => "n"})

    assert {:error, reason} = CLI.run(["update"], dir)

    assert CLI.message(reason) ==
             "v#{@next} is out but carries no omunculus package yet; nothing was installed"

    assert {:ok, output} = CLI.run(["update", "--check"], dir)

    assert output =~
             "omunculus #{@next} is available (installed #{@installed}), but it has no package yet."

    refute output =~ "^"
    assert sudo_files() == []
  end

  test "setup writes server.toml, enables the unit and keeps the file on a rerun", %{dir: dir} do
    previous = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", dir)

    on_exit(fn ->
      if previous,
        do: System.put_env("XDG_CONFIG_HOME", previous),
        else: System.delete_env("XDG_CONFIG_HOME")
    end)

    path = Path.join([dir, "omunculus", "server.toml"])
    assert {:ok, first} = CLI.run(["setup"], dir)
    assert first =~ "Wrote #{path}"
    assert first =~ "[access]"
    assert first =~ "server.md#project-access"
    assert first =~ "how-to-start-a-project.md"
    assert {:ok, _config} = Omunculus.Server.Config.load(path)

    File.write!(path, File.read!(path) <> "# mine\n")
    assert {:ok, second} = CLI.run(["setup"], dir)
    assert second =~ "already exists"
    assert File.read!(path) =~ "# mine"

    assert Enum.count(
             FakeRunner.log(),
             &(&1 == {"systemctl", ["--user", "enable", "--now", "omunculus"]})
           ) == 2
  end

  test "setup says when the unit is enabled but not running", %{dir: dir} do
    System.put_env("XDG_CONFIG_HOME", dir)
    on_exit(fn -> System.delete_env("XDG_CONFIG_HOME") end)
    fake(active: false)

    assert {:ok, output} = CLI.run(["setup"], dir)
    assert output =~ "enabled but not running"
    refute output =~ "enabled and started"
    assert File.exists?(Path.join([dir, "omunculus", "server.toml"]))
  end
end
