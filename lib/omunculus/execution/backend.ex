defmodule Omunculus.Execution.Backend do
  @moduledoc """
  Defines the transport used by isolated command backends.
  """

  alias Omunculus.Execution.{Command, Policy}

  @callback start(Command.t(), Policy.t(), pid, reference) :: {:ok, term} | {:error, term}
  @callback write(term, iodata) :: :ok | {:error, term}
  @callback close_input(term) :: :ok | {:error, term}
  @callback stop(term, term) :: :ok | {:error, term}
  @callback cleanup(term) :: :ok
end
