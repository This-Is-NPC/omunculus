defmodule Omunculus.Tools.Pack do
  @moduledoc """
  `pack` tool: imports the pack at `path` (`Omunculus.Config.Packs`) into
  the config at `config_path`, its team `depth` depths below its own when
  given. Given every role a model (`models`) and every provider of the pack
  a login of the config (`auth`), when the config loads with it — which
  refuses it while the catalog lacks a tool the pack requires — it writes the
  pack to `[[packs]]` and copies the pack's `workspace/` into the default
  workspace, keeping every file already there; either way it says what the
  pack needs and what its `environment/` holds, which it does not run.
  """

  alias Omunculus.{Config, Errors}
  alias Omunculus.Config.{Omupack, Packs}
  alias Omunculus.Jobs.Templates
  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, config_path: config_path} = input) when is_binary(config_path) do
    with {:ok, source} <- source(args, config_path),
         {:ok, models} <- pairs(args["models"], "models"),
         {:ok, auth} <- pairs(args["auth"], "auth"),
         {:ok, depth} <- depth(args["depth"]) do
      entry = %{"path" => source.path, "models" => models, "auth" => auth}

      import(
        config_path,
        source,
        if(depth > 0, do: Map.put(entry, "depth", depth), else: entry),
        Enum.map(get_in(input, [:view, "jobs"]) || [], & &1["name"])
      )
    else
      {:error, reason} -> Out.fail(failure(args["file"] || args["path"], reason))
    end
  end

  def run(_input), do: Out.fail("config_path required")

  @doc "A refusal as the sentence `pack` and `propose_pack` print."
  @spec failure(String.t() | nil, term) :: String.t()
  def failure(label, {_name, kind, _detail} = reason) when kind in [:omunculus, :header],
    do: "cannot import #{label}: #{Errors.format({:packs, reason})}"

  def failure(label, reason) when is_binary(reason), do: "cannot import #{label}: #{reason}"
  def failure(label, reason), do: "cannot import #{label}: #{inspect(reason)}"

  # Where the pack comes from: its folder, or the file that is installed
  # into the project's own folder once the import is settled.
  defp source(%{"path" => path} = args, config_path) when is_binary(path) and path != "" do
    if Args.present(args, "file"),
      do: {:error, "give the pack's folder as path or its file as file, not both"},
      else: folder(path, Path.dirname(config_path))
  end

  defp source(args, config_path) do
    case Args.present(args, "file") do
      nil -> {:error, "path or file required"}
      file -> installable(file, args, config_path)
    end
  end

  defp folder(path, base) do
    dir = Path.expand(path, base)

    with {:ok, pack} <- Packs.read(dir),
         {:ok, files} <- Omupack.list(dir) do
      {:ok,
       %{
         pack: pack,
         files: files,
         read: &File.read(Path.join(dir, &1)),
         folder: dir,
         path: path,
         card: false,
         install: fn -> {:ok, [], fn -> :ok end} end
       }}
    end
  end

  defp installable(file, args, config_path) do
    base = Path.dirname(config_path)

    with {:ok, archive} <- Omupack.read(file, base),
         {:ok, replaced} <-
           Omupack.replaces(config_path, archive.header, Args.flag?(args, "upgrade")) do
      folder = Omupack.folder(base, archive.header)
      data = Map.new(archive.files, fn {path, file} -> {path, file.data} end)

      {:ok,
       %{
         pack: archive.pack,
         files: Map.keys(archive.files),
         read: &Map.fetch(data, &1),
         card: true,
         folder: folder,
         path: Path.relative_to(folder, base),
         install: fn -> install(archive, folder, replaced) end
       }}
    end
  end

  # What it wrote, and how to take back the folder this install made.
  defp install(archive, folder, replaced) do
    with {:ok, state} <- Omupack.install(archive, folder) do
      name = "#{archive.header["name"]} #{archive.header["version"]}"

      {:ok,
       [
         if(state == :installed,
           do: "installed #{name} in #{folder}",
           else: "#{name} is already in #{folder}"
         )
         | upgraded(archive.header["name"], replaced)
       ], fn -> if(state == :installed, do: File.rm_rf(folder)) end}
    end
  end

  defp upgraded(_name, nil), do: []

  defp upgraded(name, {version, folder}),
    do: [
      "upgraded #{name} from #{version || "an unversioned pack"}; " <>
        "the old folder #{folder} stays until you remove it by hand"
    ]

  defp depth(nil), do: {:ok, 0}

  defp depth(text) do
    case Integer.parse(to_string(text)) do
      {depth, ""} when depth >= 0 -> {:ok, depth}
      _invalid -> {:error, "depth takes a whole number of depths, 0 or more"}
    end
  end

  defp pairs(nil, _key), do: {:ok, %{}}

  defp pairs(text, key) do
    text
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn pair, {:ok, acc} ->
      case String.split(String.trim(pair), "=", parts: 2) do
        [name, value] when name != "" and value != "" -> {:cont, {:ok, Map.put(acc, name, value)}}
        _malformed -> {:halt, {:error, "#{key} takes name=value pairs, comma separated"}}
      end
    end)
  end

  defp import(config_path, source, entry, jobs) do
    needs = needs(source.pack, entry)
    card = card(source.pack, source.files, source.read)

    if needs == [] do
      with {:ok, installed, undo} <- source.install.() do
        case settle(config_path, source, entry, jobs) do
          {:ok, lines, emits} ->
            Out.ok(
              Enum.join((if(source.card, do: card, else: []) ++ installed) ++ lines, "\n"),
              emits
            )

          {:error, message} ->
            undo.()
            Out.fail(message)
        end
      else
        {:error, reason} -> Out.fail(failure(entry["path"], reason))
      end
    else
      Out.fail(Enum.join(needs ++ card ++ environment(source.files, source.folder), "\n"))
    end
  end

  defp settle(config_path, source, entry, jobs) do
    with {:ok, config} <- Config.try_pack(config_path, entry),
         {:ok, emits, note} <- job_emits(source.pack, config, jobs),
         {:ok, config} <- Config.import_pack(config_path, entry) do
      {:ok,
       [imported(source.pack) | copied(source.folder, config)] ++
         note ++ environment(source.files, source.folder), emits}
    else
      {:error, {:packs, {_pack, :requires, _lacked}} = reason} -> {:error, Errors.format(reason)}
      {:error, reason} -> {:error, failure(entry["path"], reason)}
    end
  end

  # The jobs the pack's templates make, and a line saying so.
  defp job_emits(pack, config, jobs) do
    templates = Map.get(pack, "jobs", %{})

    cond do
      templates == %{} ->
        {:ok, [], []}

      is_nil(config.jobs) ->
        {:ok, [], ["job templates skipped: the project has no [jobs] table"]}

      true ->
        with {:ok, emits} <- Templates.emits(pack, config, jobs) do
          {:ok, emits, ["jobs: #{length(emits)} new of #{map_size(templates)} templates"]}
        end
    end
  end

  # What the pack names that the import does not map.
  defp needs(pack, entry) do
    for {key, label} <- [{"roles", "models"}, {"auth", "auth"}],
        missing = (get_in(pack, ["pack", key]) || []) -- Map.keys(entry[label]),
        missing != [],
        do: "#{label} needed for: #{Enum.join(missing, ", ")}"
  end

  defp imported(pack), do: "imported #{pack["pack"]["name"]}"

  defp copied(dir, config) do
    from = Path.join(dir, "workspace")
    to = Config.workspace_root(config, config.policy_workspace) || config.root

    if File.dir?(from) do
      files =
        for file <- Path.wildcard(Path.join(from, "**/*"), match_dot: true),
            File.regular?(file),
            do: Path.relative_to(file, from)

      {kept, copied} = Enum.split_with(files, &File.exists?(Path.join(to, &1)))

      for file <- copied do
        File.mkdir_p!(Path.dirname(Path.join(to, file)))
        File.cp!(Path.join(from, file), Path.join(to, file))
      end

      ["workspace #{to}: copied #{Enum.join(copied, ", ")}#{kept(kept)}"]
    else
      []
    end
  end

  defp kept([]), do: ""
  defp kept(files), do: "; kept the project's #{Enum.join(files, ", ")}"

  @doc """
  What the pack with `files` holds in `environment/`, hidden ones left out,
  as a line saying it is in `folder`, or none.
  """
  @spec environment([String.t()], String.t()) :: [String.t()]
  def environment(files, folder) do
    names =
      for file <- files,
          ["environment", name | _rest] <- [Path.split(file)],
          not String.starts_with?(name, "."),
          uniq: true,
          do: name

    if names == [],
      do: [],
      else: [
        "environment, to run yourself: #{Enum.join(Enum.sort(names), ", ")} in #{folder}/environment"
      ]
  end

  @doc """
  What the pack is and does, in words, for whoever decides to import it: its
  description, its agents, the executables it runs (the files of `tools/` and
  the commands of its MCP servers), the logins and secrets it needs and its
  job templates.
  """
  @spec card(map, [String.t()], (String.t() -> {:ok, binary} | :error | {:error, term})) ::
          [String.t()]
  def card(pack, files, read) do
    header = Map.get(pack, "pack", %{})
    servers = get_in(pack, ["mcp", "servers"]) || []

    title = Enum.join(Enum.reject([header["name"], header["version"]], &is_nil/1), " ")

    secrets =
      Enum.to_list(Map.get(pack, "secrets", %{})) ++
        for server <- servers, table = server["secrets"], do: {server["name"], table}

    [
      if(header["description"], do: "#{title}: #{header["description"]}", else: title),
      listed("agents", pack |> Map.get("agents", %{}) |> Map.keys()),
      "runs these executables:" <>
        case tools(files, read) ++
               for(
                 %{"command" => command} <- servers,
                 do: "mcp server #{Enum.join(command, " ")}"
               ) do
          [] -> " none"
          lines -> "\n" <> Enum.map_join(lines, "\n", &"  #{&1}")
        end,
      listed("needs these logins", header["auth"] || []),
      listed(
        "needs these secrets",
        for(
          {tool, table} <- secrets,
          do: "#{tool} (#{table |> Map.keys() |> Enum.sort() |> Enum.join(", ")})"
        )
      ),
      listed("job templates", pack |> Map.get("jobs", %{}) |> Map.keys())
    ]
  end

  # The tools the pack brings: `<name>: <command>`, from each `tools/<dir>/tool.toml`.
  defp tools(files, read) do
    for file <- Enum.sort(files),
        ["tools", dir, "tool.toml"] <- [Path.split(file)],
        {:ok, text} <- [read.(file)],
        {:ok, %{"name" => name, "command" => [program | args]}} <- [Toml.decode(text)],
        {:ok, path} <- [Path.safe_relative(Path.join(["tools", dir, program]))] do
      "#{name}: #{Enum.join([path | args], " ")}"
    end
  end

  defp listed(label, items) do
    "#{label}: " <> if(items == [], do: "none", else: items |> Enum.sort() |> Enum.join(", "))
  end
end
