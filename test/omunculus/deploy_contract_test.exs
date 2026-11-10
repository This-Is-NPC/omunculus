defmodule Omunculus.DeployContractTest do
  @moduledoc """
  The dream team's deploy tools against the Dokku provider, with a stub
  provider: fake `ssh`, `ssh-agent`, `ssh-add` and `git push` on PATH that
  record the calls the provider makes. The tools' answers must map each
  operation to the right calls and stay neutral.
  """
  use ExUnit.Case, async: true

  @tools Path.expand("../../packs/dream-team/tools", __DIR__)
  @neutral ~r/dokku|ssh|socket|traceback/i

  @ssh """
  #!/bin/sh
  # Logs what follows the host, then answers like the provider's commands.
  while [ $# -gt 0 ]; do
    case "$1" in dokku@*) break ;; esac
    case "$1" in -o) case "$2" in ProxyCommand=*) echo "$2" >> "$STUB_PROXY" ;; esac; shift ;; -F) shift ;; esac
    shift
  done
  echo "$*" >> "$STUB_LOG"
  [ -z "$STUB_DOWN" ] || { echo "ssh: connect failed" >&2; exit 255; }
  case "$2" in
    apps:exists) exit "${STUB_EXISTS:-0}" ;;
    ports:report) echo "${STUB_PORTS:-}" ;;
    ps:report) printf 'Deployed:  true\\nRunning:   true\\n' ;;
    logs) echo "first line of dokku log" ;;
    git:from-image) [ -z "$STUB_FROM_IMAGE" ] || { echo "$STUB_FROM_IMAGE"; exit 1; } ;;
  esac
  """

  @git """
  #!/bin/sh
  # A push is logged, with the transport it was given; the rest is git's.
  if [ "$3" = push ]; then
    echo "push $* via $GIT_SSH_COMMAND" >> "$STUB_LOG"
    if [ -n "$STUB_LOCK" ] && [ ! -e "$STUB_LOCK" ]; then
      touch "$STUB_LOCK"
      echo "deploy lock in place" >&2
      exit 1
    fi
    echo "remote: dokku@homologation built it"
    exit 0
  fi
  exec /usr/bin/git "$@"
  """

  @agent """
  #!/bin/sh
  [ -z "$STUB_NO_AGENT" ] || exec sleep 30
  touch "$3"
  exec sleep 30
  """

  setup do
    dir = Omunculus.Fixtures.tmp_dir()
    bin = Path.join(dir, "bin")
    sockets = Path.join(dir, "so ckets")
    root = Path.join(dir, "root")
    File.mkdir_p!(bin)
    File.mkdir_p!(sockets)
    File.mkdir_p!(root)

    for {name, body} <- [
          {"ssh", @ssh},
          {"git", @git},
          {"ssh-agent", @agent},
          {"ssh-add", "#!/bin/sh\ncat >/dev/null\n"}
        ] do
      File.write!(Path.join(bin, name), body)
      File.chmod!(Path.join(bin, name), 0o755)
    end

    for instance <- ~w(homologation production),
        do: File.write!(Path.join(sockets, instance <> ".sock"), "")

    File.write!(Path.join(dir, "key"), "KEY")
    log = Path.join(dir, "log")
    File.write!(log, "")

    git = fn args ->
      {out, 0} =
        System.cmd("/usr/bin/git", ["-C", root | args],
          env: [
            {"GIT_AUTHOR_NAME", "t"},
            {"GIT_AUTHOR_EMAIL", "t@t"},
            {"GIT_COMMITTER_NAME", "t"},
            {"GIT_COMMITTER_EMAIL", "t@t"}
          ]
        )

      String.trim(out)
    end

    git.(["init", "-q"])
    File.write!(Path.join(root, "deploy.toml"), ~s(app = "bakery"\nport = 3000\n))
    File.write!(Path.join(root, "Dockerfile"), "FROM scratch\n")
    git.(["add", "."])
    git.(["commit", "-q", "-m", "first"])

    id = :crypto.hash(:sha256, root) |> Base.encode16(case: :lower) |> binary_part(0, 12)

    env = [
      {"PATH", bin <> ":" <> System.get_env("PATH")},
      {"OMUNCULUS_DEPLOY", sockets},
      {"OMUNCULUS_DEPLOY_PROVIDER", "dokku"},
      {"DEPLOY_KEY_FILE", Path.join(dir, "key")},
      {"STUB_LOG", log},
      {"STUB_PROXY", Path.join(dir, "proxy")}
    ]

    {:ok,
     dir: dir,
     root: root,
     log: log,
     env: env,
     git: git,
     preview: "bakery-#{id}-hml",
     production: "bakery-#{id}",
     sockets: sockets}
  end

  defp call(tool, ctx, args \\ %{}, env \\ []) do
    input = Jason.encode!(%{name: tool, args: args, roots: [ctx.root]})
    run = Path.join([@tools, tool, "run"])
    env = Enum.uniq_by(env ++ ctx.env, &elem(&1, 0)) ++ [{"INPUT", input}]
    {output, 0} = System.cmd("sh", ["-c", ~S(printf '%s' "$INPUT" | exec "$0"), run], env: env)
    Jason.decode!(output)
  end

  defp log(ctx), do: ctx.log |> File.read!() |> String.split("\n", trim: true)

  defp pushes(ctx), do: Enum.filter(log(ctx), &String.starts_with?(&1, "push "))

  defp assert_neutral(answer),
    do: refute(answer["output"] =~ @neutral, "output names the provider: #{answer["output"]}")

  test "deploy_preview creates the app, maps its port, pushes the commit and concludes the stage",
       ctx do
    commit = ctx.git.(["rev-parse", "HEAD"])
    answer = call("deploy_preview", ctx, %{}, [{"STUB_EXISTS", "1"}])
    assert answer["ok"]
    address = "http://#{ctx.preview}.homologation.localhost:8080"
    assert answer["output"] =~ "published to the preview at #{address}"

    assert [%{"name" => "comment", "args" => %{"body" => body}}, %{"name" => "continue"}] =
             answer["chain"]

    assert body == "Published to the preview at #{address}: commit #{binary_part(commit, 0, 7)}."
    assert_neutral(answer)

    lines = log(ctx)
    assert "dokku@homologation apps:exists #{ctx.preview}" in lines
    assert "dokku@homologation apps:create #{ctx.preview}" in lines
    assert "dokku@homologation ports:set #{ctx.preview} http:80:3000" in lines
    assert [push] = pushes(ctx)
    assert push =~ "dokku@homologation:#{ctx.preview} #{commit}:refs/heads/main"
    assert push =~ "homologation.sock"
    refute Enum.any?(lines, &(&1 =~ "production"))
    assert ctx.git.(["rev-parse", "refs/deploy/preview"]) == commit
  end

  test "the app id is twelve hex digits of the root", ctx do
    assert ctx.preview =~ ~r/^bakery-[0-9a-f]{12}-hml$/
  end

  test "deploy_preview leaves a mapped port and an existing app alone", ctx do
    answer = call("deploy_preview", ctx, %{}, [{"STUB_PORTS", "http:80:3000"}])
    assert answer["ok"]
    refute Enum.any?(log(ctx), &(&1 =~ "apps:create" or &1 =~ "ports:set"))
  end

  test "deploy_preview unlocks a stale lock and pushes again", ctx do
    answer = call("deploy_preview", ctx, %{}, [{"STUB_LOCK", Path.join(ctx.dir, "lock")}])
    assert answer["ok"]
    assert "dokku@homologation apps:unlock #{ctx.preview}" in log(ctx)
    assert length(pushes(ctx)) == 2
  end

  test "build output passes on with the provider's own address scrubbed", ctx do
    answer = call("deploy_preview", ctx)
    assert answer["output"] =~ "remote: the deploy environment built it"
    assert_neutral(answer)
  end

  test "deploy.toml is read from the commit that is pushed", ctx do
    File.write!(Path.join(ctx.root, "deploy.toml"), ~s(app = "bakery"\nport = 9\n))
    assert call("deploy_preview", ctx)["ok"]
    assert "dokku@homologation ports:set #{ctx.preview} http:80:3000" in log(ctx)
  end

  test "an uncommitted deploy.toml or Dockerfile is refused with what to commit", ctx do
    ctx.git.(["rm", "-q", "--cached", "Dockerfile"])
    ctx.git.(["commit", "-q", "-m", "no dockerfile"])
    answer = call("deploy_preview", ctx)
    refute answer["ok"]
    assert answer["output"] =~ "the Dockerfile is not committed"
    assert pushes(ctx) == []

    ctx.git.(["rm", "-q", "--cached", "deploy.toml"])
    ctx.git.(["commit", "-q", "-m", "no descriptor"])
    answer = call("deploy_preview", ctx)
    assert answer["output"] =~ "deploy.toml is not committed"
  end

  test "an invalid deploy.toml is refused with what to fix", ctx do
    for {text, message} <- [
          {~s(app = "Bad App"\nport = 80\n), "app must be lowercase"},
          {~s(app = "ok"\nport = 0\n), "port must be"},
          {~s(app = "ok"\nport = 80\nenv = ["X"]\n), "keys the contract does not define: env"}
        ] do
      File.write!(Path.join(ctx.root, "deploy.toml"), text)
      ctx.git.(["commit", "-q", "-am", "change"])
      assert call("deploy_preview", ctx)["output"] =~ message
    end
  end

  test "deploy_status reports the preview app", ctx do
    answer = call("deploy_status", ctx)
    assert answer["ok"]

    assert answer["output"] ==
             "#{ctx.preview} is deployed: true, running: true, at http://#{ctx.preview}.homologation.localhost:8080"

    assert answer["chain"] == []
    assert_neutral(answer)
    assert "dokku@homologation ps:report #{ctx.preview}" in log(ctx)
  end

  test "deploy_status tells an absent app from an unreachable environment", ctx do
    assert call("deploy_status", ctx, %{}, [{"STUB_EXISTS", "1"}])["output"] ==
             "#{ctx.preview} is not deployed"

    down = call("deploy_status", ctx, %{}, [{"STUB_DOWN", "1"}])
    refute down["ok"]
    assert down["output"] == "the deploy environment is not reachable: is it up?"

    File.rm!(Path.join(ctx.sockets, "homologation.sock"))
    assert call("deploy_status", ctx)["output"] == down["output"]
  end

  test "an unreachable environment never creates the app", ctx do
    answer = call("deploy_preview", ctx, %{}, [{"STUB_DOWN", "1"}])
    refute answer["ok"]
    assert answer["output"] =~ "not reachable"
    refute Enum.any?(log(ctx), &(&1 =~ "apps:create"))
    assert pushes(ctx) == []
  end

  test "status, logs and destroy name the app from the previewed commit, not a broken file",
       ctx do
    assert call("deploy_preview", ctx)["ok"]
    File.write!(Path.join(ctx.root, "deploy.toml"), "not toml [")
    ctx.git.(["commit", "-q", "-am", "break"])
    assert call("deploy_status", ctx)["output"] =~ "#{ctx.preview} is deployed"
    assert call("deploy_logs", ctx)["ok"]
    assert call("deploy_destroy", ctx)["output"] == "#{ctx.preview} destroyed"
  end

  test "without a preview, status says exactly what to fix", ctx do
    ctx.git.(["rm", "-q", "--cached", "deploy.toml"])
    ctx.git.(["commit", "-q", "-m", "no descriptor"])
    answer = call("deploy_status", ctx)
    refute answer["ok"]
    assert answer["output"] =~ "deploy.toml is not committed"
  end

  test "deploy_logs passes the app's log on as it is", ctx do
    answer = call("deploy_logs", ctx, %{lines: 20})
    assert answer["ok"]
    assert answer["output"] == "first line of dokku log"
    assert "dokku@homologation logs #{ctx.preview} -n 20" in log(ctx)

    call("deploy_logs", ctx)
    assert "dokku@homologation logs #{ctx.preview} -n 100" in log(ctx)

    refute call("deploy_logs", ctx, %{lines: 5000})["ok"]
    assert call("deploy_logs", ctx, %{}, [{"STUB_EXISTS", "1"}])["output"] =~ "is not deployed"
  end

  test "deploy_destroy removes the preview app only, and an absent one is fine", ctx do
    answer = call("deploy_destroy", ctx)
    assert answer["ok"]
    assert answer["output"] == "#{ctx.preview} destroyed"
    assert_neutral(answer)

    assert log(ctx) == [
             "dokku@homologation apps:exists #{ctx.preview}",
             "dokku@homologation apps:destroy #{ctx.preview} --force"
           ]

    absent = call("deploy_destroy", ctx, %{}, [{"STUB_EXISTS", "1"}])
    assert absent["ok"]
    assert absent["output"] == "#{ctx.preview} is not deployed: nothing to destroy"

    refute call("deploy_destroy", ctx, %{}, [{"STUB_DOWN", "1"}])["ok"]
  end

  test "promote releases the previewed commit's image to production and concludes the release",
       ctx do
    assert call("deploy_preview", ctx)["ok"]
    File.write!(Path.join(ctx.root, "deploy.toml"), ~s(app = "bakery"\nport = 4000\n))
    ctx.git.(["commit", "-q", "-am", "later"])

    answer = call("promote", ctx, %{}, [{"STUB_EXISTS", "1"}])
    assert answer["ok"]
    address = "http://#{ctx.production}.production.localhost:9080"
    assert answer["output"] =~ "promoted to production at #{address}"

    assert [%{"name" => "comment", "args" => %{"body" => body}}, %{"name" => "continue"}] =
             answer["chain"]

    assert body =~ "Promoted to production at #{address}"
    assert_neutral(answer)

    lines = log(ctx)
    assert "dokku@production apps:create #{ctx.production}" in lines
    assert "dokku@production ports:set #{ctx.production} http:80:3000" in lines

    assert "dokku@production git:from-image #{ctx.production} dokku/#{ctx.preview}:latest" in lines
  end

  test "promote refuses when nothing was previewed", ctx do
    answer = call("promote", ctx)
    refute answer["ok"]
    assert answer["output"] =~ "run deploy_preview first"
    refute Enum.any?(log(ctx), &(&1 =~ "production"))
  end

  test "promote rebuilds from the same image when nothing changed", ctx do
    assert call("deploy_preview", ctx)["ok"]
    answer = call("promote", ctx, %{}, [{"STUB_FROM_IMAGE", "No changes detected"}])
    assert answer["ok"]
    assert "dokku@production ps:rebuild #{ctx.production}" in log(ctx)
  end

  test "the provider comes from configuration alone", ctx do
    answer = call("deploy_status", ctx, %{}, [{"OMUNCULUS_DEPLOY_PROVIDER", ""}])

    assert answer ==
             %{
               "ok" => false,
               "output" => "no deploy provider is configured",
               "emit" => [],
               "chain" => []
             }

    answer = call("deploy_status", ctx, %{}, [{"OMUNCULUS_DEPLOY_PROVIDER", "nowhere"}])
    assert answer["output"] == "the deploy provider nowhere does not exist"
  end

  test "a crash of the provider is answered neutrally, without its output", ctx do
    answer = call("deploy_status", ctx, %{}, [{"DEPLOY_KEY_FILE", "/nonexistent"}])
    refute answer["ok"]
    assert answer["output"] == "the deploy provider failed unexpectedly"
    assert_neutral(answer)
  end

  test "an agent that never starts fails clearly and in time", ctx do
    started = System.monotonic_time(:second)
    answer = call("deploy_status", ctx, %{}, [{"STUB_NO_AGENT", "1"}])
    refute answer["ok"]
    assert answer["output"] =~ "the agent holding them did not start"
    assert System.monotonic_time(:second) - started < 20
  end

  test "the socket path is quoted for the shell that runs the proxy", ctx do
    assert call("deploy_status", ctx)["ok"]
    socket = Path.join(ctx.sockets, "homologation.sock")
    assert File.read!(Path.join(ctx.dir, "proxy")) =~ "UNIX-CONNECT:'#{socket}'"
  end

  test "no manifest of a deploy tool names the provider", _ctx do
    for tool <- ~w(deploy_preview deploy_status deploy_logs deploy_destroy promote) do
      manifest = File.read!(Path.join([@tools, tool, "tool.toml"]))
      refute manifest =~ ~r/dokku|ssh|socket/i, "#{tool} names the provider"
    end
  end
end
