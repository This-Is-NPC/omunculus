defmodule Omunculus.FS.Disk do
  @moduledoc false
  @behaviour Omunculus.FS

  alias Omunculus.{Sandbox, Truncate}

  def new(cwd) do
    cwd = Path.expand(cwd)
    %{mod: __MODULE__, cwd: cwd}
  end

  @impl true
  def cwd(%{cwd: cwd}), do: cwd

  @impl true
  def read_file(fs, path, opts) do
    with {:ok, abs} <- Sandbox.resolve(fs.cwd, path) do
      case File.read(abs) do
        {:ok, bin} ->
          if String.valid?(bin) do
            {:ok, slice_text(bin, opts)}
          else
            {:error, :unsupported}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def write_file(fs, path, content) do
    with {:ok, abs} <- Sandbox.resolve(fs.cwd, path),
         :ok <- File.mkdir_p(Path.dirname(abs)),
         :ok <- File.write(abs, content) do
      {:ok, fs}
    end
  end

  @impl true
  def list_dir(fs, path) do
    with {:ok, abs} <- Sandbox.resolve(fs.cwd, path) do
      case File.ls(abs) do
        {:ok, names} ->
          entries =
            names
            |> Enum.sort()
            |> Enum.map(fn name ->
              full = Path.join(abs, name)
              if File.dir?(full), do: name <> "/", else: name
            end)

          {:ok, entries}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def walk_files(fs, path) do
    with {:ok, abs} <- Sandbox.resolve(fs.cwd, path) do
      files =
        abs
        |> Path.join("**/*")
        |> Path.wildcard(match_dot: true)
        |> Enum.filter(&File.regular?/1)
        |> Enum.filter(&Sandbox.inside?(fs.cwd, &1))
        |> Enum.sort()

      {:ok, files}
    end
  end

  defp slice_text(bin, opts) do
    offset = to_int(opts["offset"] || opts[:offset], 1)
    limit = to_int(opts["limit"] || opts[:limit], nil)
    lines = String.split(bin, "\n")
    start_idx = max(offset - 1, 0)

    taken =
      if is_nil(limit) do
        Enum.drop(lines, start_idx)
      else
        lines |> Enum.drop(start_idx) |> Enum.take(limit)
      end

    Truncate.text(Enum.join(taken, "\n"))
  end

  defp to_int(nil, default), do: default
  defp to_int(n, _default) when is_integer(n), do: n
  defp to_int(n, _default) when is_float(n), do: trunc(n)

  defp to_int(n, default) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> default
    end
  end

  defp to_int(_, default), do: default
end
