defmodule Omunculus.DeployContractTest do
  @moduledoc """
  The dream team's deploy tools against the Dokku provider, with a stub
  provider: fake `ssh`, `ssh-agent`, `ssh-add` and `git push` on PATH that
  record the calls the provider makes. The tools' answers must map each
  operation to the right calls and stay neutral.
  """
  use ExUnit.Case, async: true

  @tools Path.expand("../../packs/dream-team/tools", __DIR__)
  @neutral ~r/dokku|ssh|socket/i

  @ssh """
  #!/bin/sh
  # Logs what follows the host, then answers like the provider's commands.
  while [ $# -gt 0 ]; do
    case "$1" in dokku@*) break ;; esac
    case "$1" in -o|-F) shift ;; esac
    shift
  done
  echo "$*" >> "$STUB_LOG"
  case "$2" in
    apps:exists) exit "${STUB_EXISTS:-0}" ;;
    ports:report) echo "${STUB_PORTS:-}" ;;
    config:keys) echo "${STUB_KEYS:-}" ;;
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
    echo "remote: Dokku built it"
    exit 0
  fi
  exec /usr/bin/git "$@"
  """

  @agent """
  #!/bin/sh
  touch "$3"
  exec sleep 30
  """

  setup do
    dir = Omunculus.Fixtures.tmp_dir()
    bin = Path.join(dir, "bin")
    sockets = Path.join(dir, "sockets")
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
      System.cmd("/usr/bin/git", ["-C", root | args],
        env: [
          {"GIT_AUTHOR_NAME", "t"},
          {"GIT_AUTHOR_EMAIL", "t@t"},
          {"GIT_COMMITTER_NAME", "t"},
          {"GIT_COMMITTER_EMAIL", "t@t"}
        ]
      )
    end

    git.(["init", "-q"])

    File.write!(
      Path.join(root, "deploy.toml"),
      ~s(app = "bakery"\nport = 3000\nenv = ["API_URL"]\n)
    )

    git.(["add", "."])
    git.(["commit", "-q", "-m", "first"])

    id = :crypto.hash(:sha256, root) |> Base.encode16(case: :lower) |> binary_part(0, 6)

    env = [
      {"PATH", bin <> ":" <> System.get_env("PATH")},
      {"OMUNCULUS_DEPLOY", sockets},
      {"OMUNCULUS_DEPLOY_PROVIDER", "dokku"},
      {"DEPLOY_KEY_FILE", Path.join(dir, "key")},
      {"STUB_LOG", log},
      {"STUB_KEYS", "API_URL PORT"}
    ]

    {:ok,
     dir: dir,
     root: root,
     log: log,
     env: env,
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

  defp assert_neutral(answer),
    do: refute(answer["output"] =~ @neutral, "output names the provider: #{answer["output"]}")

  test "deploy_preview creates the app, maps its port, pushes the commit and concludes the stage",
       ctx do
    answer = call("deploy_preview", ctx, %{}, [{"STUB_EXISTS", "1"}])
    assert answer["ok"]
    address = "http://#{ctx.preview}.homologation.localhost:8080"
    assert answer["output"] =~ "published to the preview at #{address}"

    assert [%{"name" => "comment", "args" => %{"body" => body}}, %{"name" => "continue"}] =
             answer["chain"]

    assert body =~ ~r/^Published to the preview at #{Regex.escape(address)}: commit [0-9a-f]+\.$/
    assert_neutral(answer)

    lines = log(ctx)
    assert "dokku@homologation apps:exists #{ctx.preview}" in lines
    assert "dokku@homologation apps:create #{ctx.preview}" in lines
    assert "dokku@homologation ports:set #{ctx.preview} http:80:3000" in lines
    assert [push] = Enum.filter(lines, &String.starts_with?(&1, "push "))
    assert push =~ "dokku@homologation:#{ctx.preview} HEAD:refs/heads/main"
    assert push =~ "homologation.sock"
    refute Enum.any?(lines, &(&1 =~ "production"))
  end

  test "deploy_preview leaves a mapped port and an existing app alone", ctx do
    answer = call("deploy_preview", ctx, %{}, [{"STUB_PORTS", "http:80:3000"}])
    assert answer["ok"]
    lines = log(ctx)
    refute Enum.any?(lines, &(&1 =~ "apps:create" or &1 =~ "ports:set"))
  end

  test "deploy_preview names the variables the environment lacks and publishes nothing", ctx do
    answer = call("deploy_preview", ctx, %{}, [{"STUB_KEYS", "PORT"}])
    refute answer["ok"]
    assert answer["output"] =~ "the environment lacks values for: API_URL"
    assert_neutral(answer)
    refute Enum.any?(log(ctx), &String.starts_with?(&1, "push "))
  end

  test "deploy_preview unlocks a stale lock and pushes again", ctx do
    answer = call("deploy_preview", ctx, %{}, [{"STUB_LOCK", Path.join(ctx.dir, "lock")}])
    assert answer["ok"]
    lines = log(ctx)
    assert "dokku@homologation apps:unlock #{ctx.preview}" in lines
    assert length(Enum.filter(lines, &String.starts_with?(&1, "push "))) == 2
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

  test "deploy_status says an app that does not exist is not deployed", ctx do
    answer = call("deploy_status", ctx, %{}, [{"STUB_EXISTS", "1"}])
    assert answer["output"] == "#{ctx.preview} is not deployed"
  end

  test "deploy_logs reads the requested number of lines, neutrally", ctx do
    answer = call("deploy_logs", ctx, %{lines: 20})
    assert answer["ok"]
    assert answer["output"] == "first line of deploy log"
    assert "dokku@homologation logs #{ctx.preview} -n 20" in log(ctx)

    call("deploy_logs", ctx)
    assert "dokku@homologation logs #{ctx.preview} -n 100" in log(ctx)

    refute call("deploy_logs", ctx, %{lines: 5000})["ok"]
  end

  test "deploy_destroy removes the preview app only", ctx do
    answer = call("deploy_destroy", ctx)
    assert answer["ok"]
    assert answer["output"] == "#{ctx.preview} destroyed"
    assert_neutral(answer)
    assert log(ctx) == ["dokku@homologation apps:destroy #{ctx.preview} --force"]
  end

  test "promote releases the preview's image to production and concludes the release", ctx do
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

    refute Enum.any?(lines, &(&1 =~ "homologation"))
  end

  test "promote rebuilds from the same image when nothing changed", ctx do
    answer = call("promote", ctx, %{}, [{"STUB_FROM_IMAGE", "No changes detected"}])
    assert answer["ok"]
    assert "dokku@production ps:rebuild #{ctx.production}" in log(ctx)
  end

  test "a missing or invalid deploy.toml is refused with what to write", ctx do
    File.rm!(Path.join(ctx.root, "deploy.toml"))
    answer = call("deploy_status", ctx)
    refute answer["ok"]
    assert answer["output"] =~ "deploy.toml is missing"

    File.write!(Path.join(ctx.root, "deploy.toml"), ~s(app = "Bad App"\nport = 80\n))
    assert call("deploy_status", ctx)["output"] =~ "app must be lowercase"
    File.write!(Path.join(ctx.root, "deploy.toml"), ~s(app = "ok"\nport = 0\n))
    assert call("deploy_status", ctx)["output"] =~ "port must be"
    File.write!(Path.join(ctx.root, "deploy.toml"), ~s(app = "ok"\nport = 80\nhost = "x"\n))
    assert call("deploy_status", ctx)["output"] =~ "keys the contract does not define: host"
  end

  test "the provider comes from configuration alone", ctx do
    answer = call("deploy_status", ctx, %{}, [{"OMUNCULUS_DEPLOY_PROVIDER", ""}])

    assert answer == %{
             "ok" => false,
             "output" => "no deploy provider is configured",
             "emit" => [],
             "chain" => []
           }

    answer = call("deploy_status", ctx, %{}, [{"OMUNCULUS_DEPLOY_PROVIDER", "nowhere"}])
    assert answer["output"] == "the deploy provider nowhere does not exist"
  end

  test "an unreachable environment is reported without naming how", ctx do
    File.rm!(Path.join(ctx.sockets, "homologation.sock"))
    answer = call("deploy_status", ctx)
    refute answer["ok"]
    assert answer["output"] == "the deploy environment is not reachable: is it up?"
  end

  test "no manifest of a deploy tool names the provider", _ctx do
    for tool <- ~w(deploy_preview deploy_status deploy_logs deploy_destroy promote) do
      manifest = File.read!(Path.join([@tools, tool, "tool.toml"]))
      refute manifest =~ ~r/dokku|ssh|socket/i, "#{tool} names the provider"
    end
  end
end
