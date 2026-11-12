defmodule EquivalentExchange.Deploy do
  @moduledoc """
  The dream team's deploy environment (`packs/dream-team/environment/up`) for the tasks that
  publish (`deploy`): two Dokku instances, homologation and production,
  whose sockets and keys `environment/0` hands to the deploy tools through
  the variables the dream team's config reads. The tools name each project's
  apps apart; `published/1` finds, in an execution's events, the apps
  it published, the one it promoted first, and `reached/1` where each instance
  serves it. `status/3` asks an instance for a path, `look/4` loads pages in
  headless Chromium by the app's host name, `mirror/3` copies what an instance
  serves for an app, saving extensionless paths as directory indexes for the
  check, and `destroy/1` removes it from both.
  """

  @deploy Path.expand("../../packs/dream-team/environment/.state", __DIR__)
  @browser_check Path.expand("../../priv/tools/browser_check/run", __DIR__)
  @ssh ~w(-F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

  @doc """
  Sets the variables the deploy tools read from the environment's state in
  `deploy`, or says why it cannot. The sockets are named by the target of
  the `sockets` link: a unix socket address holds at most 107 bytes, which
  a path through a deep copy of the tree exceeds.
  """
  @spec environment(String.t()) :: :ok | {:error, String.t()}
  def environment(deploy \\ @deploy) do
    link = Path.join(deploy, "sockets")
    keys = Path.join(deploy, "keys")

    sockets =
      case :file.read_link_all(link) do
        {:ok, target} -> Path.expand(to_string(target), deploy)
        {:error, _not_a_link} -> link
      end

    if Enum.all?(~w(homologation production), &File.exists?(Path.join(sockets, &1 <> ".sock"))) do
      System.put_env("OMUNCULUS_DEPLOY", sockets)
      System.put_env("OMUNCULUS_DEPLOY_PROVIDER", "dokku")
      System.put_env("OMUNCULUS_HOMOLOGATION_KEY", File.read!(Path.join(keys, "homologation")))
      System.put_env("OMUNCULUS_PRODUCTION_KEY", File.read!(Path.join(keys, "production")))
      :ok
    else
      {:error, "the deploy environment is down: packs/dream-team/environment/up"}
    end
  end

  @doc """
  The apps an execution's deploy tools published, from what they answered:
  the last one promoted to production first, then the others.
  """
  @spec published([map]) :: [String.t()]
  def published(events) do
    apps = deployed(events)
    promoted = for {"promote", app} <- Enum.reverse(apps), do: app
    Enum.uniq(promoted ++ Enum.map(apps, &elem(&1, 1)))
  end

  @doc """
  Where an execution's site is served, from what its deploy tools answered:
  the app in `:homologation` (the last one previewed) and in `:production`
  (the last one promoted), nil for one never reached.
  """
  @spec reached([map]) :: %{homologation: String.t() | nil, production: String.t() | nil}
  def reached(events) do
    apps = deployed(events)

    %{
      homologation:
        Enum.find_value(Enum.reverse(apps), fn {tool, app} -> tool == "deploy_preview" && app end),
      production:
        Enum.find_value(Enum.reverse(apps), fn {tool, app} -> tool == "promote" && app end)
    }
  end

  defp deployed(events) do
    for %{type: "tool", body: %{"name" => name, "ok" => true, "output" => output}} <- events,
        name in ["deploy_preview", "promote"],
        [_, app] <- [
          Regex.run(
            ~r"http://([a-z0-9-]+?)(?:-hml)?\.(?:homologation|production)\.localhost",
            output
          )
        ],
        do: {name, app}
  end

  # The proxy port and host name each instance serves an app under.
  defp target(app, :homologation), do: {8080, app <> "-hml.homologation.localhost"}
  defp target(app, :production), do: {9080, app <> ".production.localhost"}

  @doc "The status the instance answers for `path` of `app`, or nil when it does not answer."
  @spec status(String.t(), :homologation | :production, String.t()) :: integer | nil
  def status(app, instance, path) do
    {port, host} = target(app, instance)

    case Req.get("http://127.0.0.1:#{port}" <> path,
           headers: [{"host", host}],
           retry: false,
           decode_body: false,
           redirect: false
         ) do
      {:ok, %Req.Response{status: status}} -> status
      {:error, _reason} -> nil
    end
  end

  @doc """
  What `browser_check` reports of `paths` of `app` at `viewport`, loaded in
  headless Chromium by the host name the instance serves it under: its `ok`
  and `output`, or `ok: false` with why it could not look.
  """
  @spec look(String.t(), :homologation | :production, [String.t()], String.t()) :: map
  def look(app, instance, paths, viewport) do
    {port, host} = target(app, instance)
    root = Path.join(System.tmp_dir!(), "ee-look-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    input = Path.join(root, "call.json")

    File.write!(
      input,
      Jason.encode!(%{
        args: %{port: port, host: host, paths: paths, viewports: [viewport]},
        roots: [root]
      })
    )

    try do
      {out, _status} =
        System.cmd(
          "sh",
          [
            "-c",
            ~s(deno run --no-config --no-lock --no-prompt --allow-all "$0" < "$1"),
            @browser_check,
            input
          ],
          stderr_to_stdout: true
        )

      case Jason.decode(out) do
        {:ok, %{"ok" => ok, "output" => output}} -> %{"ok" => ok, "output" => output}
        _unreadable -> %{"ok" => false, "output" => out}
      end
    after
      File.rm_rf!(root)
    end
  end

  @doc "Copies the pages and files `instance` serves for `app`, reached from its index, into `dir`."
  @spec mirror(String.t(), String.t(), :homologation | :production) :: :ok
  def mirror(app, dir, instance \\ :production),
    do: crawl(target(app, instance), dir, ["/"], MapSet.new())

  defp crawl(_target, _dir, [], _seen), do: :ok

  defp crawl({port, host} = target, dir, [path | rest], seen) do
    if MapSet.member?(seen, path) or MapSet.size(seen) >= 100 do
      crawl(target, dir, rest, seen)
    else
      case Req.get("http://127.0.0.1:#{port}" <> path,
             headers: [{"host", host}],
             retry: false,
             decode_body: false
           ) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          file =
            Path.join(
              dir,
              if(Path.extname(path) == "", do: Path.join(path, "index.html"), else: path)
            )

          File.mkdir_p!(Path.dirname(file))
          File.write!(file, body)
          crawl(target, dir, rest ++ links(path, body), MapSet.put(seen, path))

        _missing ->
          crawl(target, dir, rest, MapSet.put(seen, path))
      end
    end
  end

  # The site's own files a page names: neither another host nor an anchor.
  defp links(from, body) do
    for [_, link] <- Regex.scan(~r/(?:href|src)="([^"#?]+)"/, body),
        not String.contains?(link, ":"),
        not String.starts_with?(link, "//"),
        do: from |> Path.dirname() |> Path.join(link) |> Path.expand("/")
  end

  @doc "Removes `app` from production and homologation."
  @spec destroy(String.t()) :: :ok
  def destroy(app) do
    for {instance, port, name} <- [
          {"production", "4022", app},
          {"homologation", "3022", app <> "-hml"}
        ] do
      System.cmd(
        "ssh",
        @ssh ++
          ["-i", Path.join([@deploy, "keys", instance]), "-p", port, "dokku@127.0.0.1"] ++
          ["apps:destroy", name, "--force"],
        stderr_to_stdout: true
      )
    end

    :ok
  end
end
