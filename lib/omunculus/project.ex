defmodule Omunculus.Project do
  @moduledoc """
  A project's store connection: `open/1` opens `omunculus.sqlite3` inside
  the project directory (spec §4), `close/1` closes it.
  """

  alias Omunculus.Store

  @enforce_keys [:dir, :conn]
  defstruct [:dir, :conn]

  @type t :: %__MODULE__{dir: String.t(), conn: Exqlite.Sqlite3.db()}

  @spec open(String.t()) :: {:ok, t} | {:error, term}
  def open(dir) do
    with {:ok, conn} <- Store.open(Path.join(dir, "omunculus.sqlite3")) do
      {:ok, %__MODULE__{dir: dir, conn: conn}}
    end
  end

  @spec close(t) :: :ok
  def close(%__MODULE__{conn: conn}), do: Store.close(conn)
end
