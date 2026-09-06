defmodule Omunculus.Auth do
  @moduledoc false

  @callback headers(map()) :: [{String.t(), String.t()}]
  @callback maybe_refresh(map()) :: {:ok, map()} | {:error, term()}

  def resolve("oauth"), do: {:error, {:unsupported_auth, "oauth"}}
  def resolve("none"), do: {:ok, {Omunculus.Auth.None, %{type: "none"}}}
  def resolve("api_key"), do: {:ok, {Omunculus.Auth.ApiKey, %{type: "api_key"}}}
  def resolve(other) when is_binary(other), do: {:error, {:unsupported_auth, other}}
  def resolve(nil), do: resolve("api_key")

  def headers({mod, cred}), do: mod.headers(cred)
  def maybe_refresh({mod, cred}), do: mod.maybe_refresh(cred)
end
