defmodule Omunculus.StoreCase do
  @moduledoc """
  Test case that opens an in-memory store for each test and closes it on
  exit.
  """

  use ExUnit.CaseTemplate

  alias Omunculus.Store

  setup do
    {:ok, conn} = Store.open(":memory:")
    on_exit(fn -> Store.close(conn) end)
    %{conn: conn}
  end
end
