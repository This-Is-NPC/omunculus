defmodule Omunculus.Tools.ProposePack do
  @moduledoc """
  Builtin `propose_pack` tool: loads the config `config_path` would make
  once the pack at `path`, relative to the workspace, is imported with
  `models`, `auth` and `depth` (`Omunculus.Config.try_pack/2`) and, when it
  loads, emits a request, to whoever gave the agent its work, whose
  `apply` option calls `pack` with that
  import, and whose `deny` calls nothing; its reason gives the agent's
  `reason`, each of the pack's agents at the depth and on the model it
  would run, and what the pack's `environment/` holds, which the person
  runs. An import that does not load fails here, with why, and so does one
  whose agents lack a step their tools chain (`Omunculus.Tools.Steps`). Its manifest's
  `then` appends `end`.
  """

  alias Omunculus.{Config, Errors, Id}
  alias Omunculus.Config.{Omupack, Packs}
  alias Omunculus.Tools.{Args, Out, Pack, Steps}

  @spec run(map) :: map
  def run(%{args: args, config_path: path, roots: roots}) when is_binary(path) do
    base = List.first(roots) || Path.dirname(path)

    with nil <- Args.missing(args, ~w(reason)),
         true <- is_map(args["models"]) || "models required: each role and the model it runs on",
         {:ok, source} <- source(args, base, path),
         loaded = Config.try_pack(path, Map.put(entry(args), "path", source.load)),
         :ok <- source.done.(),
         {:ok, config} <- loaded,
         [] <- Steps.missing(config, Map.keys(Map.get(source.pack, "agents", %{}))) do
      Out.ok("", [%{"type" => "request", "body" => request(args, source, config)}])
    else
      {:error, {:packs, {_pack, :requires, _lacked}} = reason} ->
        Out.fail(Errors.format(reason))

      {:error, {_name, kind, _detail} = reason} when kind in [:omunculus, :header] ->
        Out.fail(Errors.format({:packs, reason}))

      {:error, reason} when is_binary(reason) ->
        Out.fail("the config would not load with it: #{reason}")

      {:error, reason} ->
        Out.fail("the config would not load with it: #{inspect(reason)}")

      [_ | _] = missing ->
        Out.fail("its agents would be refused:\n" <> Enum.join(missing, "\n"))

      message ->
        Out.fail(message)
    end
  end

  def run(_input), do: Out.fail("config_path required")

  # The pack, the files it holds and where `pack` is told to find it
  # (`apply`); `load` is the folder the config is tried with, a scratch
  # folder for a file, which `done` removes.
  defp source(args, base, config_path) do
    case {Args.present(args, "path"), Args.present(args, "file")} do
      {nil, nil} ->
        {:error, "path or file required"}

      {path, nil} ->
        dir = Path.expand(path, base)

        with {:ok, pack} <- Packs.read(dir),
             {:ok, files} <- Omupack.list(dir) do
          {:ok,
           %{
             pack: pack,
             files: files,
             folder: dir,
             read: &File.read(Path.join(dir, &1)),
             apply: {"path", dir},
             load: dir,
             done: fn -> :ok end
           }}
        end

      {nil, file} ->
        archived(file, args, base, config_path)

      {_path, _file} ->
        {:error, "give the pack's folder as path or its file as file, not both"}
    end
  end

  defp archived(file, args, base, config_path) do
    with {:ok, archive} <- Omupack.read(file, base),
         {:ok, _replaced} <-
           Omupack.replaces(config_path, archive.header, Args.flag?(args, "upgrade")),
         data = Map.new(archive.files, fn {path, file} -> {path, file.data} end),
         scratch = Path.join(System.tmp_dir!(), Id.new()),
         :ok <- Omupack.write(archive, scratch) do
      {:ok,
       %{
         pack: archive.pack,
         files: Map.keys(archive.files),
         read: &Map.fetch(data, &1),
         folder: Omupack.folder(Path.dirname(config_path), archive.header),
         apply:
           {"file",
            if(String.starts_with?(file, "https://"), do: file, else: Path.expand(file, base))},
         load: scratch,
         done: fn -> File.rm_rf(scratch) && :ok end
       }}
    end
  end

  defp entry(args) do
    %{"models" => args["models"] || %{}, "auth" => args["auth"] || %{}}
    |> then(&if((args["depth"] || 0) > 0, do: Map.put(&1, "depth", args["depth"]), else: &1))
  end

  defp request(args, source, config) do
    agents =
      for name <- source.pack |> Map.get("agents", %{}) |> Map.keys() |> Enum.sort(),
          agent = config.agents[name],
          do: "- #{name}: depth #{agent.depth}, model #{agent.model}"

    {key, target} = source.apply

    %{
      "reason" =>
        Enum.join(
          [
            args["reason"],
            "Import #{source.pack["pack"]["name"]} from #{target}, its agents as they would run:\n" <>
              Enum.join(agents, "\n"),
            Enum.join(Pack.card(source.pack, source.files, source.read), "\n")
          ] ++ Pack.environment(source.files, source.folder),
          "\n\n"
        ),
      "options" => %{
        "apply" => [%{"name" => "pack", "args" => pack_args(args, key, target)}],
        "deny" => []
      }
    }
  end

  defp pack_args(args, key, target) do
    pairs = &Enum.map_join(&1 || %{}, ",", fn {name, value} -> "#{name}=#{value}" end)

    %{key => target, "models" => pairs.(args["models"]), "auth" => pairs.(args["auth"])}
    |> then(
      &if((args["depth"] || 0) > 0, do: Map.put(&1, "depth", to_string(args["depth"])), else: &1)
    )
    |> then(&if(Args.flag?(args, "upgrade"), do: Map.put(&1, "upgrade", "true"), else: &1))
  end
end
