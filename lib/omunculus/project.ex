defmodule Omunculus.Project do
  @moduledoc """
  A project's store connection: `open/2` creates private state under
  `.omunculus` and opens its SQLite database, `close/1` closes it.
  `config_path` is the TOML file this project was opened with. A project
  built without opening the store (CLI tools with `config = false`) has
  `conn: nil`.
  """

  alias Omunculus.Store

  @enforce_keys [:dir, :conn, :config_path]
  defstruct [:dir, :conn, :config_path]

  @type t :: %__MODULE__{
          dir: String.t(),
          conn: Exqlite.Sqlite3.db() | nil,
          config_path: String.t()
        }

  @spec state_dir(String.t()) :: String.t()
  def state_dir(dir), do: Path.join(dir, ".omunculus")

  @spec open(String.t()) :: {:ok, t} | {:error, term}
  def open(dir), do: open(dir, Path.join(dir, "omunculus.toml"))

  @spec open(String.t(), String.t()) :: {:ok, t} | {:error, term}
  def open(dir, config_path) do
    with :ok <- File.mkdir_p(state_dir(dir)),
         {:ok, conn} <- Store.open(Path.join(state_dir(dir), "store.sqlite3")) do
      {:ok, %__MODULE__{dir: dir, conn: conn, config_path: Path.expand(config_path)}}
    end
  end

  @spec close(t) :: :ok
  def close(%__MODULE__{conn: nil}), do: :ok
  def close(%__MODULE__{conn: conn}), do: Store.close(conn)
end
