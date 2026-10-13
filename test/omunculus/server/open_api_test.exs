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

  test "a work gives the workflow it goes through beside its stage" do
    schemas = Router.openapi_routes() |> OpenAPI.document() |> Jason.encode!() |> Jason.decode!()

    assert %{"workflow" => _, "stage" => _} =
             schemas["components"]["schemas"]["Work"]["properties"]

    assert %{workflow: "page", stage: "build"} =
             Omunculus.Server.Contract.item(:works, %{
               id: "w",
               parent_id: nil,
               workspace: nil,
               assignee: "surgeon",
               title: "t",
               goal: "g",
               workflow: "page",
               stage: "build",
               state: "open",
               waiting: nil,
               created_at: "now",
               updated_at: nil
             })
  end

  test "reply requires text and offers an optional option" do
    document = Router.openapi_routes() |> OpenAPI.document() |> Jason.encode!() |> Jason.decode!()
    schema = document["components"]["schemas"]["ReplyRequest"]
    assert schema["required"] == ["body"]
    assert schema["properties"]["option"]["type"] == "string"
  end

  test "named replies recurse through neutral participants with human creation and escalation commands" do
    document = Router.openapi_routes() |> OpenAPI.document() |> Jason.encode!() |> Jason.decode!()
    schemas = document["components"]["schemas"]

    assert schemas["ReplyRequest"]["properties"]["parts"]["additionalProperties"]["$ref"] ==
             "#/components/schemas/ReplyRequest"

    assert schemas["Request"]["properties"]["status"]["enum"] == ~w(pending escalated closed)
    assert schemas["Request"]["properties"]["requester"]
    refute schemas["Request"]["properties"]["agent"]
    assert Enum.any?(Map.keys(document["paths"]), &String.ends_with?(&1, "/requests/escalate"))
    assert schemas["CreateRequest"]["required"] == ["question"]
    assert schemas["EscalateRequests"]["required"] == ~w(reason origins)
  end

  defp local_references(%{"$ref" => "#/components/schemas/" <> name} = map),
    do: [name | nested_references(Map.delete(map, "$ref"))]

  defp local_references(map) when is_map(map), do: nested_references(map)
  defp local_references(list) when is_list(list), do: Enum.flat_map(list, &local_references/1)
  defp local_references(_), do: []

  defp nested_references(map), do: map |> Map.values() |> Enum.flat_map(&local_references/1)
end
