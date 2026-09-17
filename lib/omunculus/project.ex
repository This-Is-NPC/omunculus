defmodule Omunculus.Project do
  @moduledoc """
  A project's store connection: `open/1` takes a loaded config, creates
  the store file's parent directory, and opens that SQLite database.
  `close/1` closes it. `config_path` is the TOML file this project was
  opened with. A project built without opening the store (CLI tools with
  `config = false`) has `conn: nil`.
  """

  alias Omunculus.{Config, Store}

  @enforce_keys [:dir, :conn, :config_path]
  defstruct [:dir, :conn, :config_path]

  @type t :: %__MODULE__{
          dir: String.t(),
          conn: Exqlite.Sqlite3.db() | nil,
          config_path: String.t()
        }

  @spec open(Config.t()) :: {:ok, t} | {:error, term}
  def open(%Config{} = config) do
    store = config.store.path

    with :ok <- File.mkdir_p(Path.dirname(store)),
         {:ok, conn} <- Store.open(store) do
      {:ok, %__MODULE__{dir: config.root, conn: conn, config_path: config.path}}
    end
  end

  @spec close(t) :: :ok
  def close(%__MODULE__{conn: nil}), do: :ok
  def close(%__MODULE__{conn: conn}), do: Store.close(conn)
end
