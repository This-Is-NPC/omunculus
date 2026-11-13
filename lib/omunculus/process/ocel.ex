defmodule Omunculus.Process.Ocel do
  @moduledoc """
  An `Omunculus.Process.Log` as OCEL 2.0 JSON (`objectTypes`, `eventTypes`,
  `objects`, `events`): the object types conversation, work, run, request,
  artifact and job, and one event type for each activity, its attributes
  typed from the values the events carry. Each event relates to every
  object it touches.
  """

  @object_types ~w(conversation work run request artifact job)

  @spec encode(%{events: [map], objects: [map]}) :: map
  def encode(%{events: events, objects: objects}) do
    kinds = Enum.map(events, &{&1.activity, &1.attrs})

    %{
      "objectTypes" => types(@object_types, Enum.map(objects, &{&1.type, &1.attrs})),
      "eventTypes" => types(kinds |> Enum.map(&elem(&1, 0)) |> Enum.uniq(), kinds),
      "objects" => Enum.map(objects, &object/1),
      "events" => Enum.map(events, &event/1)
    }
  end

  defp types(names, entries) do
    for name <- names do
      attrs =
        for({^name, attrs} <- entries, {key, value} <- attrs, do: {key, type(value)})
        |> Enum.uniq()
        |> Enum.sort()

      %{
        "name" => name,
        "attributes" => Enum.map(attrs, fn {key, type} -> %{"name" => key, "type" => type} end)
      }
    end
  end

  defp type(value) when is_boolean(value), do: "boolean"
  defp type(value) when is_integer(value), do: "integer"
  defp type(value) when is_float(value), do: "float"
  defp type(_value), do: "string"

  defp object(object) do
    %{
      "id" => object.id,
      "type" => object.type,
      "attributes" =>
        for(
          {key, value} <- Enum.sort(object.attrs),
          do: %{"name" => key, "time" => object.time, "value" => value}
        ),
      "relationships" =>
        for({id, qualifier} <- object.rels, do: %{"objectId" => id, "qualifier" => qualifier})
    }
  end

  defp event(event) do
    %{
      "id" => event.id,
      "type" => event.activity,
      "time" => event.at,
      "attributes" =>
        for({key, value} <- Enum.sort(event.attrs), do: %{"name" => key, "value" => value}),
      "relationships" =>
        for(
          {_type, id, qualifier} <- event.objects,
          do: %{"objectId" => id, "qualifier" => qualifier}
        )
    }
  end
end
