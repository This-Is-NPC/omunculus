defmodule Omunculus.Config do
  @moduledoc """
  Loads and validates `omunculus.toml`: a project file replaces the
  package default whole, never merges with it.
  """

  @enforce_keys [:agents]
  defstruct [:agents]

  @type agent :: %{depth: non_neg_integer, text: String.t(), tools: [String.t()] | nil}
  @type t :: %__MODULE__{agents: %{String.t() => agent}}

  @known_agent_keys ~w(depth text tools)

  @spec load(String.t()) :: {:ok, t} | {:error, term}
  def load(project_dir) do
    project_file = Path.join(project_dir, "omunculus.toml")

    path =
      if File.regular?(project_file) do
        project_file
      else
        Application.app_dir(:omunculus, "priv/omunculus.toml")
      end

    with {:ok, data} <- Toml.decode_file(path) do
      parse(data)
    end
  end

  @spec agent_at_depth(t, non_neg_integer) ::
          {:ok, {String.t(), agent}} | {:error, {:no_agent_at_depth, non_neg_integer}}
  def agent_at_depth(%__MODULE__{agents: agents}, depth) do
    agents
    |> Enum.sort_by(fn {name, _agent} -> name end)
    |> Enum.find(fn {_name, agent} -> agent.depth == depth end)
    |> case do
      nil -> {:error, {:no_agent_at_depth, depth}}
      {name, agent} -> {:ok, {name, agent}}
    end
  end

  defp parse(data) do
    case Map.keys(data) -- ["agents"] do
      [key | _] ->
        {:error, {:unknown_key, key}}

      [] ->
        case Map.get(data, "agents", %{}) do
          agents when map_size(agents) == 0 -> {:error, :no_agents}
          agents -> parse_agents(agents)
        end
    end
  end

  defp parse_agents(agents) do
    Enum.reduce_while(agents, {:ok, %{}}, fn {name, data}, {:ok, acc} ->
      case parse_agent(name, data) do
        {:ok, agent} -> {:cont, {:ok, Map.put(acc, name, agent)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, agents} -> {:ok, %__MODULE__{agents: agents}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_agent(name, data) when is_map(data) do
    case Map.keys(data) -- @known_agent_keys do
      [key | _] ->
        {:error, {:agent, name, {:unknown_key, key}}}

      [] ->
        with {:ok, depth} <- fetch_depth(data),
             {:ok, text} <- fetch_text(data),
             {:ok, tools} <- fetch_tools(data) do
          {:ok, %{depth: depth, text: text, tools: tools}}
        else
          {:error, key} -> {:error, {:agent, name, {:invalid, key}}}
        end
    end
  end

  defp parse_agent(name, _data), do: {:error, {:agent, name, {:invalid, :depth}}}

  defp fetch_depth(data) do
    case Map.fetch(data, "depth") do
      {:ok, depth} when is_integer(depth) and depth >= 0 -> {:ok, depth}
      _ -> {:error, :depth}
    end
  end

  defp fetch_text(data) do
    case Map.fetch(data, "text") do
      {:ok, text} when is_binary(text) -> {:ok, text}
      _ -> {:error, :text}
    end
  end

  defp fetch_tools(data) do
    case Map.fetch(data, "tools") do
      :error ->
        {:ok, nil}

      {:ok, tools} when is_list(tools) ->
        if Enum.all?(tools, &is_binary/1), do: {:ok, tools}, else: {:error, :tools}

      _ ->
        {:error, :tools}
    end
  end
end
