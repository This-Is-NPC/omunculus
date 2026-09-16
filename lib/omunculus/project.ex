defmodule Omunculus.Project do
  @moduledoc """
  A project's store connection: `open/1` creates private state under
  `.omunculus` and opens its SQLite database, `close/1` closes it.
  """

  alias Omunculus.Store

  @enforce_keys [:dir, :conn]
  defstruct [:dir, :conn]

  @type t :: %__MODULE__{dir: String.t(), conn: Exqlite.Sqlite3.db()}

  @spec state_dir(String.t()) :: String.t()
  def state_dir(dir), do: Path.join(dir, ".omunculus")

  @spec open(String.t()) :: {:ok, t} | {:error, term}
  def open(dir) do
    with :ok <- File.mkdir_p(state_dir(dir)),
         {:ok, conn} <- Store.open(Path.join(state_dir(dir), "store.sqlite3")) do
      {:ok, %__MODULE__{dir: dir, conn: conn}}
    end
  end

  @spec close(t) :: :ok
  def close(%__MODULE__{conn: conn}), do: Store.close(conn)
end
