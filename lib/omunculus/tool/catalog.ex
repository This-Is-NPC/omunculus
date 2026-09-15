defmodule Omunculus.Tool.Catalog do
  @moduledoc """
  Discovers tool/hook folders on disk, per spec §8.4: builtin, user, then
  project root, the most specific winning on a shared `name`.
  """

  require Logger

  alias Omunculus.Tool.Manifest

  @spec roots(String.t()) :: [Path.t()]
  def roots(project_dir) do
    [
      Application.app_dir(:omunculus, "priv/tools"),
      Path.expand("~/.omunculus/tools"),
      Path.join(project_dir, "tools")
    ]
  end

  @spec discover([Path.t()]) :: %{String.t() => Manifest.t()}
  def discover(roots) do
    Enum.reduce(roots, %{}, fn root, acc ->
      if File.dir?(root) do
        root |> subfolders() |> Enum.reduce(acc, &load_into(&2, &1))
      else
        acc
      end
    end)
  end

  @spec with_trigger(%{String.t() => Manifest.t()}, String.t()) :: %{String.t() => Manifest.t()}
  def with_trigger(catalog, trigger) do
    catalog
    |> Enum.filter(fn {_name, manifest} -> Manifest.triggered_by?(manifest, trigger) end)
    |> Map.new()
  end

  @spec hooks_for(%{String.t() => Manifest.t()}, String.t()) :: [Manifest.t()]
  def hooks_for(catalog, event_type) do
    catalog
    |> Map.values()
    |> Enum.filter(&(event_type in &1.events))
    |> Enum.sort_by(& &1.name)
  end

  defp subfolders(root) do
    root
    |> File.ls!()
    |> Enum.map(&Path.join(root, &1))
    |> Enum.filter(&File.dir?/1)
  end

  defp load_into(acc, dir) do
    case manifest_path(dir) do
      {:ok, path} ->
        case Manifest.load(path) do
          {:ok, manifest} -> Map.put(acc, manifest.name, manifest)
          {:error, reason} -> log_skip(path, reason) && acc
        end

      {:error, reason} ->
        log_skip(dir, reason) && acc

      :skip ->
        acc
    end
  end

  defp manifest_path(dir) do
    tool = Path.join(dir, "tool.toml")
    hook = Path.join(dir, "hook.toml")

    case {File.regular?(tool), File.regular?(hook)} do
      {true, true} -> {:error, :ambiguous}
      {true, false} -> {:ok, tool}
      {false, true} -> {:ok, hook}
      {false, false} -> :skip
    end
  end

  defp log_skip(path, reason) do
    Logger.warning("skipping tool manifest at #{path}: #{inspect(reason)}")
    true
  end
end
