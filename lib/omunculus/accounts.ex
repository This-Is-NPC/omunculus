defmodule Omunculus.Accounts do
  @moduledoc """
  The project's `[accounts]`: names for the identities a request can be
  addressed to, each `{kind = "agent", agent = ...}` or `{kind = "human",
  issuer = ..., subject = ...}`. The names are the project's own.
  """
  alias Omunculus.Participant

  @spec parse(map | nil, %{String.t() => map}) :: {:ok, %{String.t() => map}} | {:error, term}
  def parse(nil, _agents), do: {:ok, %{}}

  def parse(accounts, agents) when is_map(accounts) do
    Enum.reduce_while(accounts, {:ok, %{}}, fn {name, identity}, {:ok, acc} ->
      cond do
        name == "" or not Participant.valid?(identity) ->
          {:halt, {:error, {:accounts, {:invalid, name}}}}

        identity["kind"] == "agent" and not Map.has_key?(agents, identity["agent"]) ->
          {:halt, {:error, {:accounts, {:invalid, name}}}}

        Map.has_key?(agents, name) ->
          {:halt, {:error, {:accounts, {:agent_name, name}}}}

        true ->
          {:cont, {:ok, Map.put(acc, name, identity)}}
      end
    end)
  end

  def parse(_accounts, _agents), do: {:error, {:accounts, :invalid}}

  @doc "The identity `name` stands for: an account's, else the agent of that name."
  @spec identity(Omunculus.Config.t(), String.t()) :: {:ok, map} | :error
  def identity(config, name) do
    case config.accounts do
      %{^name => identity} ->
        {:ok, identity}

      _other ->
        if Map.has_key?(config.agents, name), do: {:ok, Participant.agent(name)}, else: :error
    end
  end

  @doc "Every name `to` accepts, sorted."
  @spec names(Omunculus.Config.t()) :: [String.t()]
  def names(config), do: Enum.sort(Map.keys(config.accounts) ++ Map.keys(config.agents))
end
