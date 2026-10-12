defmodule EquivalentExchange.Deploy do
  @moduledoc """
  The dream team's deploy environment (`packs/dream-team/environment/up`) for the tasks that
  publish (`deploy`): two Dokku instances, homologation and production,
  whose sockets and keys `environment/0` hands to the deploy tools through
  the variables the dream team's config reads. The tools name each project's
  apps apart; `published/1` finds, in an execution's events, the apps
  it published, the one it promoted first, `mirror/2` copies what
  production serves for an app, saving extensionless paths as directory indexes
  for the check, and `destroy/1` removes it
  from both.
  """

  @deploy Path.expand("../../packs/dream-team/environment/.state", __DIR__)
  @ssh ~w(-F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

  @doc "Sets the variables the deploy tools read, or says why it cannot."
  @spec environment() :: :ok | {:error, String.t()}
  def environment do
    sockets = Path.join(@deploy, "sockets")
    keys = Path.join(@deploy, "keys")

    if Enum.all?(~w(homologation production), &File.exists?(Path.join(sockets, &1 <> ".sock"))) do
      System.put_env("OMUNCULUS_DEPLOY", sockets)
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
    apps =
      for %{type: "tool", body: %{"name" => name, "ok" => true, "output" => output}} <- events,
          name in ["deploy_preview", "promote"],
          [_, app] <- [
            Regex.run(
              ~r"http://([a-z0-9-]+?)(?:-hml)?\.(?:homologation|production)\.localhost",
              output
            )
          ],
          do: {name, app}

    promoted = for {"promote", app} <- Enum.reverse(apps), do: app
    Enum.uniq(promoted ++ Enum.map(apps, &elem(&1, 1)))
  end

  @doc "Copies the pages and files production serves for `app`, reached from its index, into `dir`."
  @spec mirror(String.t(), String.t()) :: :ok
  def mirror(app, dir), do: crawl(app, dir, ["/"], MapSet.new())

  defp crawl(_app, _dir, [], _seen), do: :ok

  defp crawl(app, dir, [path | rest], seen) do
    if MapSet.member?(seen, path) or MapSet.size(seen) >= 100 do
      crawl(app, dir, rest, seen)
    else
      case Req.get("http://127.0.0.1:9080" <> path,
             headers: [{"host", "#{app}.production.localhost"}],
             retry: false,
             decode_body: false
           ) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          file =
            Path.join(dir, if(Path.extname(path) == "", do: Path.join(path, "index.html"), else: path))

          File.mkdir_p!(Path.dirname(file))
          File.write!(file, body)
          crawl(app, dir, rest ++ links(path, body), MapSet.put(seen, path))

        _missing ->
          crawl(app, dir, rest, MapSet.put(seen, path))
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
