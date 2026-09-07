defmodule Omunculus.EventsTest do
  use ExUnit.Case, async: true

  alias Omunculus.Events

  @permission_types ~w(
    permission.requested
    permission.granted
    permission.denied
    permission.revoked
  )

  test "catalog includes permission, policy, and inbox types" do
    for type <- @permission_types ++ ["policy.changed", "inbox.read"] do
      assert Events.known?(type), "missing #{type}"
    end
  end

  test "permission.requested is an interceptable run event" do
    assert %{kind: :event, emitted_by: ["Run"], required: ["request_id", "tool"]} =
             Events.spec("permission.requested")

    assert Events.interceptable?("permission.requested")
    refute Events.injectable?("permission.requested")
  end

  test "permission.granted is an injectable command" do
    assert %{kind: :command, emitted_by: emitters, required: ["request_id", "kind", "granter"]} =
             Events.spec("permission.granted")

    assert "Run" in emitters
    assert "CLI" in emitters
    assert Events.interceptable?("permission.granted")
    assert Events.injectable?("permission.granted")
  end

  test "permission.denied is injectable but not interceptable" do
    assert %{kind: :command, required: ["request_id", "reason"]} =
             Events.spec("permission.denied")

    refute Events.interceptable?("permission.denied")
    assert Events.injectable?("permission.denied")
  end

  test "permission.revoked is an interceptable injectable command" do
    assert %{kind: :command, required: ["request_id"]} = Events.spec("permission.revoked")

    assert Events.interceptable?("permission.revoked")
    assert Events.injectable?("permission.revoked")
  end

  test "policy.changed is a cli event without required payload fields" do
    assert %{kind: :event, emitted_by: ["CLI"], required: []} = Events.spec("policy.changed")

    refute Events.interceptable?("policy.changed")
    refute Events.injectable?("policy.changed")
  end

  test "inbox.read is an injectable cli command" do
    assert %{kind: :command, emitted_by: ["CLI"], required: ["id"]} = Events.spec("inbox.read")

    refute Events.interceptable?("inbox.read")
    assert Events.injectable?("inbox.read")
  end

  test "validate enforces required payload fields" do
    assert :ok =
             Events.validate(%{
               type: "permission.requested",
               kind: :event,
               schema_version: "1",
               payload: %{"request_id" => "req-1", "tool" => "edit"}
             })

    assert {:error, {:missing_payload_fields, "permission.granted", missing}} =
             Events.validate(%{
               type: "permission.granted",
               kind: :command,
               schema_version: "1",
               payload: %{"request_id" => "req-1"}
             })

    assert ["granter", "kind"] = Enum.sort(missing)
  end
end
