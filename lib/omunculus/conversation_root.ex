defmodule Omunculus.ConversationRoot do
  @moduledoc """
  The folder a conversation works in when the config sets `[project]
  conversations`: `<workspace root>/<conversations>/<conversation id>`,
  the root of its runs and calls in place of the workspace's own, so one
  conversation's files are out of another's reach. The first time it is
  needed it starts as a copy of the workspace's files, leaving out the
  conversations' folder and what omunculus itself keeps there — the
  config file, the store, the changes, the attachments and the logins.
  It is copied beside the folder and renamed into place, so runs opening
  at once see one copy or none.
  """

  alias Omunculus.Config
  alias Omunculus.Path, as: FilesystemPath

  @doc """
  The folder of `conversation_id` in the workspace whose root is
  `workspace_root`, copied from the workspace first if it does not exist
  yet.
  """
  @spec root(Config.t(), String.t(), String.t()) :: String.t()
  def root(%Config{conversations: dir} = config, workspace_root, conversation_id)
      when is_binary(dir) do
    folders = Path.expand(dir, workspace_root)
    folder = Path.join(folders, conversation_id)

    unless File.dir?(folder), do: seed(config, workspace_root, folders, folder)
    folder
  end

  defp seed(config, workspace_root, folders, folder) do
    staged = Path.join(folders, ".#{Path.basename(folder)}.#{Omunculus.Id.new()}")
    File.mkdir_p!(staged)
    copy(workspace_root, staged, [folders | kept(config, workspace_root)])

    # Another run may have put its copy in place first: it is the same.
    case File.rename(staged, folder) do
      :ok -> :ok
      {:error, _reason} -> File.rm_rf!(staged)
    end
  end

  defp copy(from, to, left_out) do
    for name <- File.ls!(from),
        source = Path.join(from, name),
        not Enum.any?(left_out, &FilesystemPath.within?(&1, source)) do
      target = Path.join(to, name)

      case File.lstat!(source).type do
        :directory ->
          File.mkdir!(target)
          copy(source, target, left_out)

        :symlink ->
          File.ln_s!(File.read_link!(source), target)

        :regular ->
          File.cp!(source, target)

        _socket_or_device ->
          :ok
      end
    end
  end

  # What omunculus keeps, which may lie inside a workspace: the store's
  # own directory, or, when that is the workspace, the store and every
  # file named after it — its log, scratch and socket.
  defp kept(config, workspace_root) do
    store = Path.expand(config.store.path)
    dir = Path.dirname(store)
    workspace_root = Path.expand(workspace_root)

    store_kept =
      cond do
        dir == workspace_root ->
          for name <- File.ls!(dir),
              String.starts_with?(name, Path.basename(store)),
              do: Path.join(dir, name)

        FilesystemPath.within?(workspace_root, dir) ->
          [dir]

        true ->
          []
      end

    [config.path, config.store.changes, config.store.attachments, config.auth.store]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.expand/1)
    |> Kernel.++(store_kept)
  end
end
