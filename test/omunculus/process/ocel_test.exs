defmodule Omunculus.Process.OcelTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.Process.{Log, Ocel}
  alias Omunculus.ProcessFixtures
  alias Omunculus.Store

  @attribute_types ~w(string integer float boolean time)

  defp export(conn) do
    %{works: works, conversations: [conversation | _]} = ProcessFixtures.seed(conn)
    {:ok, %{runs: [run | _]}} = Store.log(conn, nil)
    ProcessFixtures.traffic(conn, conversation, works.done_a, run.id)
    {:ok, raw} = Store.log(conn, nil)

    # Through JSON, as a consumer reads it.
    raw |> Log.build() |> Ocel.encode() |> Jason.encode!() |> Jason.decode!()
  end

  defp declared(types), do: Map.new(types, &{&1["name"], &1})

  # The OCEL 2.0 JSON schema's shape: typed attribute declarations, objects
  # and events with ids, types, times and relationships to objects that exist.
  defp valid?(log) do
    assert Map.keys(log) |> Enum.sort() == ~w(eventTypes events objectTypes objects)

    for type <- log["objectTypes"] ++ log["eventTypes"] do
      assert is_binary(type["name"])

      for attribute <- type["attributes"] do
        assert is_binary(attribute["name"])
        assert attribute["type"] in @attribute_types
      end
    end

    object_types = declared(log["objectTypes"])
    event_types = declared(log["eventTypes"])
    ids = MapSet.new(log["objects"], &{&1["type"], &1["id"]})
    assert MapSet.size(ids) == length(log["objects"])
    object_ids = MapSet.new(log["objects"], & &1["id"])

    for object <- log["objects"] do
      assert Map.has_key?(object_types, object["type"])
      declared = object_types[object["type"]]["attributes"] |> Enum.map(& &1["name"])

      for attribute <- object["attributes"] do
        assert attribute["name"] in declared
        assert {:ok, _time, 0} = DateTime.from_iso8601(attribute["time"])
        assert Map.has_key?(attribute, "value")
      end

      for relationship <- object["relationships"] do
        assert relationship["objectId"] in object_ids
        assert is_binary(relationship["qualifier"])
      end
    end

    assert log["events"] |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() ==
             length(log["events"])

    for event <- log["events"] do
      assert Map.has_key?(event_types, event["type"])
      assert {:ok, _time, 0} = DateTime.from_iso8601(event["time"])
      declared = event_types[event["type"]]["attributes"] |> Enum.map(& &1["name"])
      assert Enum.all?(event["attributes"], &(&1["name"] in declared))
      assert event["relationships"] != []
      assert Enum.all?(event["relationships"], &(&1["objectId"] in object_ids))
    end
  end

  test "the export has the OCEL 2.0 shape", %{conn: conn} do
    valid?(export(conn))
  end

  test "the object types are conversation, work, run, request, artifact and job", %{conn: conn} do
    log = export(conn)

    assert Enum.map(log["objectTypes"], & &1["name"]) ==
             ~w(conversation work run request artifact job)

    present = log["objects"] |> Enum.map(& &1["type"]) |> Enum.uniq() |> Enum.sort()
    assert present == ~w(artifact conversation request run work)
  end

  test "stage moves, tool calls, refusals, requests, artifacts and work ends are events", %{
    conn: conn
  } do
    types = export(conn)["eventTypes"] |> declared()

    for activity <-
          ~w(read write bash continue) ++
            [
              "enter to_do",
              "enter review",
              "model reply",
              "work done",
              "work cancelled",
              "request raised",
              "request answered",
              "artifact written"
            ] do
      assert Map.has_key?(types, activity), activity
    end

    attributes = types["bash"]["attributes"] |> Map.new(&{&1["name"], &1["type"]})
    assert %{"agent" => "string", "ok" => "boolean", "duration" => "float"} = attributes

    assert %{"usd" => "float", "tokens" => "integer", "model" => "string"} =
             types["model reply"]["attributes"] |> Map.new(&{&1["name"], &1["type"]})
  end

  test "an event relates to every object it touches", %{conn: conn} do
    log = export(conn)
    request = Enum.find(log["events"], &(&1["type"] == "request raised"))
    types = Map.new(log["objects"], &{&1["id"], &1["type"]})

    assert request["relationships"] |> Enum.map(&types[&1["objectId"]]) |> Enum.sort() ==
             ~w(conversation request run work)

    artifact = Enum.find(log["events"], &(&1["type"] == "artifact written"))

    assert artifact["relationships"] |> Enum.map(&types[&1["objectId"]]) |> Enum.sort() ==
             ~w(artifact conversation run work)
  end
end
