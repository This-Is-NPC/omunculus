defmodule Omunculus.Tools.Logout do
  @moduledoc """
  Builtin `logout` CLI tool: removes a provider's credential from `[auth] store`.
  """

  alias Omunculus.{Auth, Config}
  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, config_path: config_path}) when is_binary(config_path) do
    case Args.missing(args, ~w(provider)) do
      nil ->
        with {:ok, config} <- Config.load(config_path) do
          logout(config, args["provider"])
        else
          {:error, reason} -> Out.fail(inspect(reason))
        end

      message ->
        Out.fail(message)
    end
  end

  def run(_input), do: Out.fail("config_path required")

  defp logout(config, provider_id) do
    case Map.fetch(config.auth.providers, provider_id) do
      :error ->
        Out.fail(Out.unknown_auth_provider(provider_id))

      {:ok, _provider} ->
        case Auth.delete(config, provider_id) do
          :ok -> Out.ok(Out.logged_out(provider_id))
          {:error, reason} -> Out.fail(inspect(reason))
        end
    end
  end
end
