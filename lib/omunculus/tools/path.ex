defmodule Omunculus.Tools.Path do
  @moduledoc "Checks lexical and symlink-resolved paths against roots and the store's path permissions."

  alias Omunculus.Execution.Policy
  alias Omunculus.Path, as: FilesystemPath

  def permissions(input), do: input |> Map.get(:view, %{}) |> Map.get("paths", %{})

  @spec resolve([String.t()], String.t(), map, Policy.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def resolve([], path, _permissions, _policy), do: {:error, "path outside roots: #{path}"}

  def resolve(roots, path, permissions, %Policy{} = policy) do
    absolute = Path.expand(path, hd(roots))

    with {:ok, real} <- FilesystemPath.canonical(absolute),
         true <- permitted?(absolute, roots, permissions),
         true <- permitted?(real, canonical_paths(roots), canonical_permissions(permissions)),
         true <- Policy.readable?(policy, real) do
      {:ok, real}
    else
      _ -> {:error, "path outside roots: #{path}"}
    end
  end

  @doc "Whether `path` resolves inside the roots, the permissions and the policy."
  @spec allowed?([String.t()], String.t(), map, Policy.t()) :: boolean
  def allowed?(roots, path, permissions, policy),
    do: match?({:ok, _}, resolve(roots, path, permissions, policy))

  @doc "The entry `name` of the directory `dir` as a listing shows it: a directory ends in `/`."
  @spec entry(String.t(), String.t()) :: String.t()
  def entry(dir, name) do
    if File.dir?(Path.join(dir, name)), do: name <> "/", else: name
  end

  @doc "Whether the policy lets a tool write the resolved `absolute`, named `path` in the error."
  @spec writable(Policy.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def writable(%Policy{} = policy, absolute, path) do
    cond do
      Policy.writable?(policy, absolute) ->
        :ok

      policy.read_write == [] ->
        {:error, "path is not writable: #{path}; writing needs sandbox.write"}

      true ->
        {:error, "path is not writable: #{path}"}
    end
  end

  @doc """
  Writes `content` to `absolute` whole or not at all: into a file beside
  it first, then renamed over it, so no reader sees half a file.
  """
  @spec write_atomic(String.t(), iodata) :: :ok | {:error, String.t()}
  def write_atomic(absolute, content) do
    staged =
      Path.join(Path.dirname(absolute), ".#{Path.basename(absolute)}.#{Omunculus.Id.new()}")

    with :ok <- File.mkdir_p(Path.dirname(absolute)),
         :ok <- File.write(staged, content),
         :ok <- File.rename(staged, absolute) do
      :ok
    else
      {:error, reason} ->
        File.rm(staged)
        {:error, "could not write #{Path.basename(absolute)}: #{:file.format_error(reason)}"}
    end
  end

  defp permitted?(path, roots, permissions) do
    allowed = Enum.any?(Map.get(permissions, "allowed", []), &FilesystemPath.within?(&1, path))
    denied = Enum.any?(Map.get(permissions, "denied", []), &FilesystemPath.within?(&1, path))

    restricted =
      Enum.any?(Map.get(permissions, "restricted", []), &FilesystemPath.within?(&1, path))

    not denied and
      (allowed or (not restricted and Enum.any?(roots, &FilesystemPath.within?(&1, path))))
  end

  defp canonical_permissions(permissions),
    do: Map.new(permissions, fn {key, paths} -> {key, canonical_paths(paths)} end)

  defp canonical_paths(paths) do
    Enum.flat_map(paths, fn path ->
      case FilesystemPath.canonical(Path.expand(path)) do
        {:ok, real} -> [real]
        _ -> []
      end
    end)
  end
end
