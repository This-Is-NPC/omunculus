defmodule Omunculus.Auth.None do
  @moduledoc false
  @behaviour Omunculus.Auth

  @impl true
  def headers(_cred), do: []

  @impl true
  def maybe_refresh(cred), do: {:ok, cred}
end
