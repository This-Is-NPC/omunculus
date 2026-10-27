defmodule Omunculus.Execution.Session do
  @moduledoc """
  Ends a started execution that a caller speaks to over its stdin and stdout.
  """

  alias Omunculus.Execution

  @doc "Stops `handle`; a process already gone counts as stopped."
  @spec stop(Execution.Handle.t()) :: :ok | {:error, term}
  def stop(handle) do
    Execution.stop(handle, :completed)
  catch
    :exit, _reason -> :ok
  end
end
