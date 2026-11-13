defmodule Omunculus.Config.Omupack do
  @moduledoc """
  A pack as one file: `<name>-<version>.omupack`, a gzip tar of the pack's
  folder with a root `omupack.toml` that holds the `[pack]` header
  (`Omunculus.Config.Packs.header/1`) and, for every other file, its
  `sha256` and `mode`.

  `export/2` writes one. `read/2` takes a file or an https URL and refuses
  it unless every entry is a plain file or folder inside the archive, the
  files are the manifest's own and each matches its hash, and the header
  agrees with the `pack.toml` it holds and with the running omunculus.
  `install/2` lays the files in the folder `folder/2` names, under the
  project's `.omunculus/packs`, and `replaces/3` says whether that would
  replace a version of the pack the project has imported.
  """

  alias Omunculus.Config.Packs
  alias Omunculus.Id

  @manifest "omupack.toml"
  @skipped ~w(.git _build .omunculus)

  @type file :: %{data: binary, mode: non_neg_integer, sha256: String.t()}
  @type t :: %{header: %{String.t() => String.t()}, pack: map, files: %{String.t() => file}}

  @doc """
  Writes the pack in `dir` to the file `out` or, when `nil`,
  `<name>-<version>.omupack`, each relative to `base`; returns the file's
  path and sha256.
  """
  @spec export(String.t(), String.t() | nil, String.t()) ::
          {:ok, String.t(), String.t()} | {:error, term}
  def export(dir, out, base) do
    with {:ok, pack} <- Packs.read(dir),
         {:ok, header} <- Packs.header(pack),
         {:ok, paths} <- list(dir),
         {:ok, files} <- read_files(dir, List.delete(paths, @manifest)),
         out = Path.expand(out || "#{header["name"]}-#{header["version"]}.omupack", base),
         :ok <- write_tar(out, manifest(header, files), files),
         {:ok, bytes} <- File.read(out) do
      {:ok, out, sha256(bytes)}
    else
      {:error, reason} when is_atom(reason) -> {:error, :file.format_error(reason) |> to_string()}
      error -> error
    end
  end

  @doc "The regular files under `dir`, relative and sorted, VCS and build leftovers left out."
  @spec list(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def list(dir) do
    with {:ok, paths} <- walk(dir, "") do
      {:ok, Enum.sort(paths)}
    end
  end

  defp walk(root, rel) do
    with {:ok, names} <- ls(Path.join(root, rel)) do
      names
      |> Enum.reject(&(&1 in @skipped))
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
        path = Path.join(rel, name)

        case File.lstat(Path.join(root, path)) do
          {:ok, %{type: :regular}} ->
            {:cont, {:ok, [path | acc]}}

          {:ok, %{type: :directory}} ->
            with {:ok, inner} <- walk(root, path), do: {:cont, {:ok, inner ++ acc}}

          {:ok, %{type: type}} ->
            {:halt, {:error, "#{path} is a #{type}: a pack holds files and folders only"}}

          {:error, reason} ->
            {:halt, {:error, "cannot read #{path}: #{:file.format_error(reason)}"}}
        end
      end)
    end
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> {:ok, names}
      {:error, reason} -> {:error, "cannot read #{dir}: #{:file.format_error(reason)}"}
    end
  end

  defp read_files(dir, paths) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, acc} ->
      full = Path.join(dir, path)

      with {:ok, data} <- File.read(full),
           {:ok, %{mode: mode}} <- File.stat(full) do
        {:cont, {:ok, Map.put(acc, path, file(data, Bitwise.band(mode, 0o777)))}}
      else
        {:error, reason} ->
          {:halt, {:error, "cannot read #{path}: #{:file.format_error(reason)}"}}
      end
    end)
  end

  defp file(data, mode), do: %{data: data, mode: mode, sha256: sha256(data)}

  defp manifest(header, files) do
    Omunculus.Config.Toml.encode(%{
      "pack" => header,
      "files" =>
        Map.new(files, fn {path, file} ->
          {path, %{"sha256" => file.sha256, "mode" => Integer.to_string(file.mode, 8)}}
        end)
    })
  end

  defp write_tar(out, manifest, files) do
    entries = [
      {@manifest, manifest} | for({path, file} <- Enum.sort(files), do: {path, file.data})
    ]

    with {:ok, tar} <- :erl_tar.open(String.to_charlist(out), [:write, :compressed]) do
      result =
        Enum.reduce_while(entries, :ok, fn {path, data}, :ok ->
          case :erl_tar.add(tar, {String.to_charlist(path), data}, []) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      :ok = :erl_tar.close(tar)
      result
    end
    |> case do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot write #{out}: #{inspect(reason)}"}
    end
  end

  @doc """
  The pack in `file`, a path relative to `base` or an https URL, checked
  against its manifest and the running omunculus; nothing is written.
  """
  @spec read(String.t(), String.t()) :: {:ok, t} | {:error, term}
  def read(file, base) do
    with {:ok, binary} <- fetch(file, base), do: open(binary)
  end

  defp fetch("http://" <> _rest, _base), do: {:error, "only https URLs are fetched"}

  defp fetch("https://" <> _rest = url, _base) do
    case Req.get(url, decode_body: false, retry: false) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "#{url} answered #{status}"}
      {:error, reason} -> {:error, "cannot fetch #{url}: #{Exception.message(reason)}"}
    end
  end

  defp fetch(file, base) do
    case File.read(Path.expand(file, base)) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, "cannot read #{file}: #{:file.format_error(reason)}"}
    end
  end

  defp open(binary) do
    with {:ok, entries} <- table(binary),
         :ok <- safe(entries),
         {:ok, contents} <- extract(binary),
         {:ok, manifest} <- decode(contents[@manifest], @manifest),
         {:ok, header} <- Packs.header(%{"pack" => manifest["pack"]}),
         :ok <- Packs.compatible(header["name"], header["omunculus"]),
         {:ok, files} <- verify(Map.get(manifest, "files", %{}), Map.delete(contents, @manifest)),
         {:ok, pack} <- decode(contents["pack.toml"], "pack.toml"),
         :ok <- agree(Packs.header(pack), header) do
      {:ok, %{header: header, pack: pack, files: files}}
    end
  end

  defp agree({:ok, header}, header), do: :ok
  defp agree(_other, _header), do: {:error, "the header of pack.toml differs from the manifest's"}

  defp table(binary) do
    case :erl_tar.table({:binary, binary}, [:compressed, :verbose]) do
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> {:error, "not an omupack, a gzip tar: #{inspect(reason)}"}
    end
  end

  defp safe(entries) do
    names =
      Enum.map(entries, fn {name, _type, _size, _mtime, _mode, _uid, _gid} -> to_string(name) end)

    Enum.find_value(entries, :ok, fn {name, type, _size, _mtime, _mode, _uid, _gid} ->
      name = to_string(name)

      cond do
        type not in [:regular, :directory] ->
          {:error, "unsafe entry #{name}: a #{type} is not a plain file or folder"}

        Path.safe_relative(name) != {:ok, name} ->
          {:error, "unsafe entry #{inspect(name)}: it is outside the pack's folder"}

        Enum.count(names, &(&1 == name)) > 1 ->
          {:error, "#{name} appears more than once"}

        true ->
          nil
      end
    end)
  end

  defp extract(binary) do
    case :erl_tar.extract({:binary, binary}, [:memory, :compressed]) do
      {:ok, files} -> {:ok, Map.new(files, fn {name, data} -> {to_string(name), data} end)}
      {:error, reason} -> {:error, "cannot read the archive: #{inspect(reason)}"}
    end
  end

  defp decode(nil, name), do: {:error, "the archive has no #{name}"}

  defp decode(text, name) do
    case Toml.decode(text) do
      {:ok, table} -> {:ok, table}
      {:error, _reason} -> {:error, "#{name} is not TOML"}
    end
  end

  # Every file the manifest lists is there with its hash, and no other.
  defp verify(listed, contents) when is_map(listed) do
    missing = Enum.sort(Map.keys(listed) -- Map.keys(contents))
    extra = Enum.sort(Map.keys(contents) -- Map.keys(listed))

    cond do
      missing != [] -> {:error, "#{hd(missing)} is in the manifest and not in the archive"}
      extra != [] -> {:error, "#{hd(extra)} is in the archive and not in the manifest"}
      true -> hashed(listed, contents)
    end
  end

  defp verify(_listed, _contents), do: {:error, "the manifest's files are not a table"}

  defp hashed(listed, contents) do
    Enum.reduce_while(Enum.sort(listed), {:ok, %{}}, fn {path, spec}, {:ok, acc} ->
      data = Map.fetch!(contents, path)

      with %{"sha256" => hash, "mode" => mode} <- spec,
           {bits, ""} when bits in 0..0o777 <- parse_mode(mode),
           true <- hash == sha256(data) do
        {:cont, {:ok, Map.put(acc, path, file(data, bits))}}
      else
        %{} -> {:halt, {:error, "#{path} has no sha256 and mode in the manifest"}}
        _mismatch -> {:halt, {:error, "#{path} does not match the hash in the manifest"}}
      end
    end)
  end

  defp parse_mode(mode) when is_binary(mode), do: Integer.parse(mode, 8)
  defp parse_mode(_mode), do: :error

  @doc "The folder `header`'s pack installs to under the project at `base`."
  @spec folder(String.t(), map) :: String.t()
  def folder(base, header),
    do: Path.join([base, ".omunculus", "packs", "#{header["name"]}-#{header["version"]}"])

  @doc """
  Lays the files of `archive` in `folder`: `{:ok, :installed}`, `{:ok, :present}`
  when it already holds exactly these files, or a refusal when it holds others.
  """
  @spec install(t, String.t()) :: {:ok, :installed | :present} | {:error, String.t()}
  def install(archive, folder) do
    if File.exists?(folder) do
      same(archive, folder)
    else
      staged = folder <> "." <> Id.new() <> ".part"

      with :ok <- File.mkdir_p(Path.dirname(folder)),
           :ok <- write(archive, staged),
           :ok <- File.rename(staged, folder) do
        {:ok, :installed}
      else
        {:error, reason} ->
          File.rm_rf(staged)
          {:error, "cannot install into #{folder}: #{message(reason)}"}
      end
    end
  end

  defp same(archive, folder) do
    with {:ok, paths} <- list(folder),
         {:ok, held} <- read_files(folder, paths) do
      if Map.new(held, fn {path, file} -> {path, file.sha256} end) ==
           Map.new(archive.files, fn {path, file} -> {path, file.sha256} end),
         do: {:ok, :present},
         else:
           {:error,
            "#{folder} holds a different #{archive.header["name"]} #{archive.header["version"]}: " <>
              "its files do not match this file's hashes; the version number is the pack's identity, so ask its author for a new one"}
    end
  end

  @doc "Writes the files of `archive` under `dir`, which it creates."
  @spec write(t, String.t()) :: :ok | {:error, term}
  def write(archive, dir) do
    Enum.reduce_while(archive.files, :ok, fn {path, file}, :ok ->
      target = Path.join(dir, path)

      with :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.write(target, file.data),
           :ok <- File.chmod(target, file.mode) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp message(reason) when is_atom(reason), do: :file.format_error(reason) |> to_string()
  defp message(reason), do: inspect(reason)

  @doc """
  The version and folder of the pack of `header`'s name that the config at
  `config_path` imports at another version, or `nil` when it imports none.
  Refuses that unless `upgrade?`.
  """
  @spec replaces(String.t(), map, boolean) ::
          {:ok, nil | {String.t() | nil, String.t()}} | {:error, String.t()}
  def replaces(config_path, header, upgrade?) do
    base = Path.dirname(Path.expand(config_path))

    found =
      with {:ok, data} <- Toml.decode_file(config_path),
           entries when is_list(entries) <- Map.get(data, "packs", []) do
        for entry <- entries,
            {:ok, folder, %{"pack" => %{"name" => name} = table}} <- [Packs.load(entry, base)],
            name == header["name"],
            table["version"] != header["version"],
            do: {table["version"], folder}
      else
        _unreadable -> []
      end

    case {found, upgrade?} do
      {[], _upgrade} ->
        {:ok, nil}

      {[old | _], true} ->
        {:ok, old}

      {[{version, folder} | _], false} ->
        {:error,
         "#{header["name"]} is already imported at version #{version || "(none)"} from #{folder}; " <>
           "installing #{header["version"]} replaces it: add --upgrade to do that"}
    end
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
