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

    # `auth` is the status of the sudo password check, `status` of pacman.
    def run_tty(command, args, opts) do
      Agent.update(__MODULE__, &[{command, args} | &1])
      if opts[:echo] == false, do: Agent.update(__MODULE__, &[{:echo_off, command} | &1])
      # Everything the command can call after pacman must already be loaded.
      loaded = for app <- [:omunculus, :elixir], m <- Application.spec(app, :modules), do: m
      all_loaded = Enum.all?(loaded, &Code.loaded?/1)
      Agent.update(__MODULE__, &[{:loaded, all_loaded} | &1])
      if "-v" in args, do: opt(:auth), else: opt(:status)
    end

    def terminal, do: opt(:terminal)
    def executable("pkexec"), do: opt(:pkexec)

    def finish(message), do: Agent.update(__MODULE__, &[{:finish, message} | &1])

    defp opt(key), do: Application.get_env(:omunculus, :fake_runner)[key]
    def log, do: Agent.get(__MODULE__, &Enum.reverse/1)
  end

  # Serves a latest release listing the assets and their bytes.
  defmodule Stub do
    @behaviour Plug
    def init(opts), do: opts

    def call(%{request_path: "/latest"} = conn, opts) do
      base = "http://127.0.0.1:#{opts.port.()}/moved/"

      assets =
        for name <- Map.keys(opts.files),
            do: %{"name" => name, "browser_download_url" => base <> name}

      conn
      |> put_resp_header("x-agent", get_req_header(conn, "user-agent") |> hd())
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"tag_name" => opts.tag, "assets" => assets}))
    end

    def call(%{request_path: "/moved/" <> name} = conn, _opts),
      do: conn |> put_resp_header("location", "/files/" <> name) |> send_resp(302, "")

    def call(%{request_path: "/files/" <> name} = conn, opts) do
      send(opts.owner, {:downloaded, name})
      send_resp(conn, 200, Map.fetch!(opts.files, name))
    end
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
    opts = %{owner: self(), tag: tag, files: files, port: fn -> Agent.get(agent, & &1) end}

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

    Application.put_env(:omunculus, :fake_runner,
      apps: false,
      active: true,
      pkexec: "/usr/bin/pkexec",
      terminal: "/dev/pts/1",
      auth: 0,
      status: 0
    )

    on_exit(fn ->
      Enum.each([:runner, :fake_runner, :release_api], &Application.delete_env(:omunculus, &1))
    end)

    %{dir: Fixtures.tmp_dir()}
  end

  @pacman ["pacman", "-U", "--noconfirm"]
  @prompt "[sudo] password to install omunculus: "

  defp sudo_files, do: for({"pkexec", @pacman ++ files} <- FakeRunner.log(), do: files)

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

  test "update elevates through pkexec when it is installed", %{dir: dir} do
    serve("v#{@next}")
    assert {:ok, _output} = CLI.run(["update"], dir)

    assert [{"pkexec", @pacman ++ [file]}] =
             Enum.filter(FakeRunner.log(), &match?({"pkexec", _}, &1))

    assert Path.basename(file) == @core
    refute {:echo_off, "sudo"} in FakeRunner.log()
  end

  test "update asks sudo for the password with echo off, then runs pacman", %{dir: dir} do
    fake(pkexec: nil)
    serve("v#{@next}")
    assert {:ok, _output} = CLI.run(["update"], dir)

    assert [
             {"sudo", ["-S", "-p", @prompt, "-v"]},
             {:echo_off, "sudo"},
             {:loaded, true},
             {"sudo", ["-n", "pacman", "-U", "--noconfirm", file]},
             {:loaded, true}
           ] = Enum.filter(FakeRunner.log(), &(elem(&1, 0) in ["sudo", :echo_off, :loaded]))

    assert Path.basename(file) == @core
  end

  test "update without pkexec or a terminal refuses and downloads nothing", %{dir: dir} do
    fake(pkexec: nil, terminal: nil)
    serve("v#{@next}")
    assert {:error, reason} = CLI.run(["update"], dir)

    assert CLI.message(reason) ==
             "pkexec is not installed, and there is no terminal for sudo to ask for the password; " <>
               "install polkit, or run omunculus update in a terminal"

    refute_received {:downloaded, _}
    assert FakeRunner.log() == [{"pacman", ["-Q", "omunculus-apps"]}]
  end

  test "update says a refused password and a failed pacman", %{dir: dir} do
    serve("v#{@next}")

    for status <- [126, 127] do
      fake(status: status)
      assert {:error, reason} = CLI.run(["update"], dir)
      assert CLI.message(reason) == "the password was not given; nothing was installed"
    end

    fake(status: 1)
    assert {:error, reason} = CLI.run(["update"], dir)
    assert CLI.message(reason) == "pacman -U failed with exit status 1"

    fake(status: 137)
    assert {:error, reason} = CLI.run(["update"], dir)
    assert CLI.message(reason) == "pacman -U was stopped by a signal"
  end

  test "update says a refused sudo password and installs nothing", %{dir: dir} do
    fake(pkexec: nil, auth: 1)
    serve("v#{@next}")
    assert {:error, reason} = CLI.run(["update"], dir)
    assert CLI.message(reason) == "the password was not given; nothing was installed"
    refute Enum.any?(FakeRunner.log(), &match?({"sudo", ["-n" | _]}, &1))
  end

  test "update loads all its code before pacman replaces it, then finishes at once", %{dir: dir} do
    serve("v#{@next}")
    assert {:ok, _output} = CLI.run(["update"], dir)
    log = FakeRunner.log()
    assert {:loaded, true} in log
    assert {:finish, "omunculus " <> _} = List.last(Enum.filter(log, &match?({:finish, _}, &1)))
  end

  test "update never logs the redirect of a download", %{dir: dir} do
    serve("v#{@next}")
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    log = ExUnit.CaptureLog.capture_log(fn -> assert {:ok, _} = CLI.run(["update"], dir) end)

    refute log =~ "redirecting"
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
