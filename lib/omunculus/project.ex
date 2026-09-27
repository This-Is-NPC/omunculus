defmodule Omunculus.Project do
  @moduledoc """
  A project's store connection: `open/1` takes a loaded config, creates
  the store file's parent directory, and opens that SQLite database
  through its owner process (`Store.Connection`). `close/1` closes it.
  `config_path` is the TOML file this project was opened with. A project
  built without opening the store (CLI tools with `config = false`) has
  `conn: nil`. `cycle` is the `Omunculus.Cycle` the runs opened through
  this project join, `nil` outside one.
  """

  alias Omunculus.{Config, Store}
  alias Omunculus.Store.Lock

  @enforce_keys [:dir, :conn, :config_path]
  defstruct [:dir, :conn, :config_path, :lock, :global_limits, cycle: nil]

  @type t :: %__MODULE__{
          dir: String.t(),
          conn: Store.Connection.t() | nil,
          config_path: String.t(),
          cycle: pid | nil,
          lock: port | nil,
          global_limits: map | nil
        }

  @spec open(Config.t(), keyword) :: {:ok, t} | {:error, term}
  def open(%Config{} = config, opts \\ []) do
    store = config.store.path

    with :ok <- File.mkdir_p(Path.dirname(store)),
         {:ok, lock} <- maybe_lock(store, opts) do
      case Store.open(store) do
        {:ok, conn} ->
          {:ok, %__MODULE__{dir: config.root, conn: conn, config_path: config.path, lock: lock}}

        error ->
          if lock, do: Lock.release(lock)
          error
      end
    end
  end

  defp maybe_lock(store, opts) do
    if Keyword.get(opts, :lock, false), do: Lock.acquire(store), else: {:ok, nil}
  end

  @spec close(t) :: :ok
  def close(%__MODULE__{conn: nil}), do: :ok

  def close(%__MODULE__{conn: conn, lock: lock}) do
    Store.close(conn)
    if lock, do: Lock.release(lock)
    :ok
  end
end
