defmodule Omunculus.Server.OpenAPITest do
  use ExUnit.Case, async: true

  alias Omunculus.Server.{OpenAPI, Router}

  test "the generated document has valid path parameters and local schema references" do
    document = Router.openapi_routes() |> OpenAPI.document() |> Jason.encode!() |> Jason.decode!()
    schemas = document["components"]["schemas"]

    assert length(Router.openapi_routes()) ==
             Enum.reduce(document["paths"], 0, fn {_path, methods}, count ->
               count + map_size(methods)
             end)

    for {path, methods} <- document["paths"], {_method, operation} <- methods do
      path_names =
        Regex.scan(~r/\{([a-z_]+)\}/, path, capture: :all_but_first)
        |> Enum.map(&hd/1)
        |> Enum.sort()

      parameter_names =
        operation["parameters"]
        |> Enum.filter(&(&1["in"] == "path" and &1["required"]))
        |> Enum.map(& &1["name"])
        |> Enum.sort()

      assert parameter_names == path_names
      assert map_size(operation["responses"]) > 0
    end

    for name <- local_references(document) do
      assert Map.has_key?(schemas, name)
    end
  end

  defp local_references(%{"$ref" => "#/components/schemas/" <> name} = map),
    do: [name | nested_references(Map.delete(map, "$ref"))]

  defp local_references(map) when is_map(map), do: nested_references(map)
  defp local_references(list) when is_list(list), do: Enum.flat_map(list, &local_references/1)
  defp local_references(_), do: []

  defp nested_references(map), do: map |> Map.values() |> Enum.flat_map(&local_references/1)
end
