defmodule Omunculus.FS.Memory do
  @moduledoc false
  @behaviour Omunculus.FS

  alias Omunculus.Truncate

  def new(files \\ %{}) do
    files =
      files
      |> Enum.map(fn {path, content} -> {normalize(path), content} end)
      |> Map.new()

    %{mod: __MODULE__, cwd: "/work", files: files}
  end

  @impl true
  def cwd(%{cwd: cwd}), do: cwd

  @impl true
  def read_file(fs, path, opts) do
    key = normalize(path)

    case Map.fetch(fs.files, key) do
      {:ok, content} when is_binary(content) -> {:ok, slice_text(content, opts)}
      {:ok, _} -> {:error, :eisdir}
      :error -> {:error, :enoent}
    end
  end

  @impl true
  def write_file(fs, path, content) do
    {:ok, %{fs | files: Map.put(fs.files, normalize(path), content)}}
  end

  @impl true
  def list_dir(fs, path) do
    dir = normalize(path) |> String.trim_trailing("/")
    prefix = if dir in ["", "."], do: "", else: dir <> "/"

    children =
      fs.files
      |> Map.keys()
      |> Enum.filter(&(prefix == "" or String.starts_with?(&1, prefix)))
      |> Enum.map(fn key ->
        rest = if prefix == "", do: key, else: String.replace_prefix(key, prefix, "")

        case String.split(rest, "/", parts: 2) do
          [name] -> name
          [name, _] -> name <> "/"
        end
      end)
      |> Enum.reject(&(&1 in ["", "/"]))
      |> Enum.uniq()
      |> Enum.sort()

    {:ok, children}
  end

  @impl true
  def walk_files(fs, path) do
    dir = normalize(path) |> String.trim_trailing("/")
    prefix = if dir in ["", "."], do: "", else: dir <> "/"

    files =
      fs.files
      |> Enum.filter(fn {_k, v} -> is_binary(v) end)
      |> Enum.map(fn {k, _} -> k end)
      |> Enum.filter(fn key ->
        dir in ["", "."] or key == dir or String.starts_with?(key, prefix)
      end)
      |> Enum.sort()
      |> Enum.map(&Path.join(fs.cwd, &1))

    {:ok, files}
  end

  defp normalize(path) do
    path
    |> String.replace(~r|^/work/|, "")
    |> String.replace_leading("/", "")
    |> Path.relative_to(".")
  end

  defp slice_text(bin, opts) do
    offset = opts["offset"] || opts[:offset] || 1
    offset = if is_integer(offset), do: offset, else: 1
    limit = opts["limit"] || opts[:limit]
    lines = String.split(bin, "\n")

    taken =
      lines
      |> Enum.drop(max(offset - 1, 0))
      |> then(&if(limit, do: Enum.take(&1, trunc_num(limit)), else: &1))

    Truncate.text(Enum.join(taken, "\n"))
  end

  defp trunc_num(n) when is_integer(n), do: n
  defp trunc_num(n) when is_float(n), do: trunc(n)
  defp trunc_num(_), do: 2_000
end
