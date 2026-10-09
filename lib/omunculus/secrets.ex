defmodule Omunculus.Secrets do
  @moduledoc """
  The secrets a tool's process receives. A `command` tool's are the names
  its manifest declares, each bound in the config's `[secrets.<tool>]` to
  an `[auth]` provider; an MCP server's are those its own `secrets` table
  binds. Each resolves through `Omunculus.Auth`, as a model's credential
  does, right before the process starts. A declared name left unbound, or
  a bound name the tool does not declare, refuses the call. `mask/2`
  replaces their values in whatever a call returns before it is recorded.
  """

  alias Omunculus.{Auth, Config}
  alias Omunculus.Tool.Manifest

  @type values :: %{String.t() => String.t()}

  @doc "The values a call of the tool `manifest` hands to its process."
  @spec for_tool(Config.t(), Manifest.t()) :: {:ok, values} | {:error, term}
  def for_tool(config, %Manifest{mcp: %{secrets: binding}}), do: resolve(config, binding)

  def for_tool(config, %Manifest{name: tool, secrets: names}) do
    binding = Map.get(config.secrets, tool, %{})

    cond do
      unbound = Enum.find(names, &(not Map.has_key?(binding, &1))) ->
        {:error, {:secrets, tool, {:unbound, unbound}}}

      undeclared = Enum.find(Map.keys(binding), &(&1 not in names)) ->
        {:error, {:secrets, tool, {:undeclared, undeclared}}}

      true ->
        resolve(config, binding)
    end
  end

  @doc "Resolves each name of `binding` to the credential of its provider."
  @spec resolve(Config.t(), %{String.t() => String.t()}) :: {:ok, values} | {:error, term}
  def resolve(config, binding) do
    Enum.reduce_while(binding, {:ok, %{}}, fn {name, provider}, {:ok, values} ->
      case Auth.credential(config, provider) do
        {:ok, %{access: value}} when is_binary(value) and value != "" ->
          {:cont, {:ok, Map.put(values, name, value)}}

        {:ok, _none} ->
          {:halt, {:error, {:secrets, :unresolved, provider}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  @doc "`term` with every value of `values` in its strings replaced by `***`."
  @spec mask(term, values) :: term
  def mask(term, values) when map_size(values) == 0, do: term

  def mask(term, values) do
    # The longest first, so a value that holds another is masked whole.
    secrets = values |> Map.values() |> Enum.sort_by(&(-byte_size(&1)))
    hide(term, secrets)
  end

  defp hide(text, secrets) when is_binary(text),
    do: Enum.reduce(secrets, text, &String.replace(&2, &1, "***"))

  defp hide(list, secrets) when is_list(list), do: Enum.map(list, &hide(&1, secrets))

  defp hide(%_{} = struct, _secrets), do: struct

  defp hide(map, secrets) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, hide(value, secrets)} end)

  defp hide(tuple, secrets) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> hide(secrets) |> List.to_tuple()

  defp hide(other, _secrets), do: other
end
