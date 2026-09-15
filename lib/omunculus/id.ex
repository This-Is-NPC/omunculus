defmodule Omunculus.Id do
  @moduledoc """
  Text ids for every row in the store: 16 random bytes, lowercase hex.
  """

  @spec new() :: String.t()
  def new do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
