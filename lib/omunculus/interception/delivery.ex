defmodule Omunculus.Interception.Delivery do
  @moduledoc "Declarative projection of an immutable source envelope for an actor."

  alias Omunculus.{EventCore, Event.Envelope}

  def for_request(core, request_id) when is_binary(request_id) do
    with {:ok, %{type: "interception.requested"} = request} <- EventCore.fetch(core, request_id),
         {:ok, source} <- EventCore.fetch(core, request.payload["source_event_id"]) do
      {:ok, event(source, request.payload["rule"])}
    else
      _ -> {:error, :unknown_interception_request}
    end
  end

  def for_request(_, _), do: {:error, :unknown_interception_request}

  def event(source, rule) do
    source
    |> Envelope.to_map()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> project(Map.take(rule, ["exclude", "exclude_items"]))
  end

  def valid?(input) when is_map(input) do
    Enum.all?(Map.keys(input), &(&1 in ["exclude", "exclude_items"])) and
      paths?(Map.get(input, "exclude", [])) and
      is_list(Map.get(input, "exclude_items", [])) and
      Enum.all?(Map.get(input, "exclude_items", []), &valid_filter?/1)
  end

  def valid?(_), do: false

  def project(source, input) do
    source =
      Enum.reduce(Map.get(input, "exclude", []), source, &remove(&2, String.split(&1, ".")))

    Enum.reduce(Map.get(input, "exclude_items", []), source, fn filter, acc ->
      update(acc, String.split(filter["path"], "."), fn
        items when is_list(items) ->
          Enum.reject(items, fn
            item when is_map(item) ->
              Enum.all?(Map.get(filter, "match", %{}), fn {k, v} -> Map.get(item, k) == v end) and
                Enum.all?(Map.get(filter, "missing", []), &is_nil(Map.get(item, &1)))

            _ ->
              false
          end)

        value ->
          value
      end)
    end)
  end

  defp valid_filter?(filter) when is_map(filter) do
    Enum.all?(Map.keys(filter), &(&1 in ["path", "match", "missing"])) and
      path?(filter["path"]) and is_map(Map.get(filter, "match", %{})) and
      paths?(Map.get(filter, "missing", [])) and
      (map_size(Map.get(filter, "match", %{})) > 0 or Map.get(filter, "missing", []) != [])
  end

  defp valid_filter?(_), do: false
  defp paths?(paths), do: is_list(paths) and Enum.all?(paths, &path?/1)

  defp path?(path),
    do: is_binary(path) and Regex.match?(~r/^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$/, path)

  defp remove(map, [key]) when is_map(map), do: Map.delete(map, key)

  defp remove(map, [key | rest]) when is_map(map) do
    if Map.has_key?(map, key), do: Map.update!(map, key, &remove(&1, rest)), else: map
  end

  defp remove(value, _), do: value

  defp update(value, [], fun), do: fun.(value)

  defp update(map, [key | rest], fun) when is_map(map) do
    if Map.has_key?(map, key), do: Map.update!(map, key, &update(&1, rest, fun)), else: map
  end

  defp update(value, _, _), do: value
end
