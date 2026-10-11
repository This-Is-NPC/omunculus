defmodule Omunculus.Tools.Pack do
  @moduledoc """
  `pack` tool: imports the pack at `path` (`Omunculus.Config.Packs`) into
  the config at `config_path`, its team `depth` depths below its own when
  given. Given every role a model (`models`) and every provider of the pack
  a login of the config (`auth`), and with every tool the pack `requires`
  in the project's catalog once it is imported, it writes the
  pack to `[[packs]]` and copies the pack's `workspace/` into the default
  workspace, keeping every file already there; either way it says what the
  pack needs and what its `environment/` holds, which it does not run.
  """

  alias Omunculus.Config
  alias Omunculus.Config.Packs
  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, config_path: config_path}) when is_binary(config_path) do
    dir = Path.expand(args["path"] || "", Path.dirname(config_path))

    with nil <- Args.missing(args, ~w(path)),
         {:ok, pack} <- Packs.read(dir),
         {:ok, models} <- pairs(args["models"], "models"),
         {:ok, auth} <- pairs(args["auth"], "auth"),
         {:ok, depth} <- depth(args["depth"]) do
      entry = %{"path" => args["path"], "models" => models, "auth" => auth}

      import(
        config_path,
        dir,
        pack,
        if(depth > 0, do: Map.put(entry, "depth", depth), else: entry)
      )
    else
      {:error, reason} -> Out.fail("cannot import #{args["path"]}: #{inspect(reason)}")
      message -> Out.fail(message)
    end
  end

  def run(_input), do: Out.fail("config_path required")

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

  defp import(config_path, dir, pack, entry) do
    needs = needs(pack, entry)

    if needs == [] do
      with {:ok, config} <- Config.try_pack(config_path, entry),
           [] <- unmet(config, pack),
           {:ok, config} <- Config.import_pack(config_path, entry) do
        Out.ok(Enum.join([imported(pack) | copied(dir, config)] ++ environment(dir), "\n"))
      else
        [_ | _] = unmet -> Out.fail(requires(unmet))
        {:error, reason} -> Out.fail("cannot import #{entry["path"]}: #{inspect(reason)}")
      end
    else
      Out.fail(Enum.join(needs ++ environment(dir), "\n"))
    end
  end

  @doc "The tools `pack` requires that `config`'s catalog lacks."
  @spec unmet(Config.t(), map) :: [String.t()]
  def unmet(config, pack) do
    catalog = Omunculus.Tool.Catalog.discover(config.tools)
    (get_in(pack, ["pack", "requires"]) || []) -- Map.keys(catalog)
  end

  @doc "What to say of the tools a pack requires that the project lacks."
  @spec requires([String.t()]) :: String.t()
  def requires(unmet),
    do:
      "it requires tools the project lacks: #{Enum.join(unmet, ", ")}; import the pack that brings them first"

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

  @doc "What the pack in `dir` holds in `environment/`, hidden files left out, as a line, or none."
  @spec environment(String.t()) :: [String.t()]
  def environment(dir) do
    from = Path.join(dir, "environment")

    files =
      if File.dir?(from),
        do: from |> File.ls!() |> Enum.reject(&String.starts_with?(&1, ".")),
        else: []

    if files == [],
      do: [],
      else: ["environment, to run yourself: #{Enum.join(Enum.sort(files), ", ")} in #{from}"]
  end
end
