defmodule Omunculus.Auth.ApiKey do
  @moduledoc false
  @behaviour Omunculus.Auth

  @impl true
  def headers(%{key: key}) when is_binary(key) and key != "" do
    [{"authorization", "Bearer #{key}"}]
  end

  def headers(_), do: []

  @impl true
  def maybe_refresh(cred), do: {:ok, cred}
end
