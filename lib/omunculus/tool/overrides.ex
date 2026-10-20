defmodule Omunculus.Tool.Overrides do
  @moduledoc """
  Per-tool overrides a ceiling layer carries under `overrides.<tool>`:
  `then` replaces the manifest's `then`, `chains` restricts the manifest's
  `chains`, `schema` names one of the manifest's `schemas`. `merge/1` folds
  layers from least to most specific, each key on its own. `apply/2` turns
  the manifests of a catalog into the ones a run uses: the served schema
  becomes `parameters`.
  """

  alias Omunculus.Tool.Manifest

  @type t :: %{String.t() => %{optional(String.t()) => [String.t()] | String.t()}}

  @keys ~w(then chains schema)

  @spec parse(term) :: {:ok, t} | {:error, term}
  def parse(data) when is_map(data) do
    Enum.reduce_while(data, {:ok, %{}}, fn {tool, value}, {:ok, acc} ->
      case parse_tool(value) do
        {:ok, override} -> {:cont, {:ok, Map.put(acc, tool, override)}}
        {:error, reason} -> {:halt, {:error, {:overrides, tool, reason}}}
      end
    end)
  end

  def parse(_data), do: {:error, {:invalid, :overrides}}

  defp parse_tool(value) when is_map(value) do
    case Map.keys(value) -- @keys do
      [key | _] ->
        {:error, {:unknown_key, key}}

      [] ->
        Enum.reduce_while(value, {:ok, value}, fn {key, entry}, ok ->
          if valid?(key, entry),
            do: {:cont, ok},
            else: {:halt, {:error, {:invalid, atom(key)}}}
        end)
    end
  end

  defp parse_tool(_value), do: {:error, {:invalid, :table}}

  defp atom("then"), do: :then
  defp atom("chains"), do: :chains
  defp atom("schema"), do: :schema

  defp valid?("schema", entry), do: is_binary(entry) and entry != ""
  defp valid?(_list_key, entry), do: is_list(entry) and Enum.all?(entry, &is_binary/1)

  @spec merge([t]) :: t
  def merge(layers) do
    Enum.reduce(layers, %{}, fn layer, acc ->
      Map.merge(acc, layer, fn _tool, left, right -> Map.merge(left, right) end)
    end)
  end

  @spec apply(%{String.t() => Manifest.t()}, t) ::
          {:ok, %{String.t() => Manifest.t()}} | {:error, term}
  def apply(catalog, overrides) do
    Enum.reduce_while(overrides, {:ok, catalog}, fn {tool, override}, {:ok, acc} ->
      case Map.fetch(acc, tool) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, manifest} ->
          case override_manifest(manifest, override) do
            {:ok, manifest} -> {:cont, {:ok, Map.put(acc, tool, manifest)}}
            {:error, reason} -> {:halt, {:error, {:overrides, tool, reason}}}
          end
      end
    end)
  end

  defp override_manifest(manifest, override) do
    with {:ok, chains} <- chains(manifest.chains, Map.get(override, "chains")),
         then = Map.get(override, "then", manifest.then),
         :ok <- Manifest.validate_then(then, chains),
         {:ok, parameters} <- schema(manifest, Map.get(override, "schema")) do
      {:ok, %{manifest | chains: chains, then: then, parameters: parameters}}
    end
  end

  defp chains(manifest_chains, nil), do: {:ok, manifest_chains}

  defp chains(manifest_chains, chains) do
    case Enum.find(chains, &(&1 not in manifest_chains)) do
      nil -> {:ok, Enum.filter(manifest_chains, &(&1 in chains))}
      name -> {:error, {:not_chainable, name}}
    end
  end

  defp schema(manifest, nil), do: {:ok, manifest.parameters}

  defp schema(manifest, variant) do
    case Map.fetch(manifest.schemas, variant) do
      {:ok, parameters} -> {:ok, parameters}
      :error -> {:error, {:unknown_schema, variant}}
    end
  end
end
