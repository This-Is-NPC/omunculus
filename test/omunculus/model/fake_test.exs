defmodule Omunculus.Model.FakeTest do
  use ExUnit.Case, async: true

  alias Omunculus.Model.Fake

  defp never_call, do: fn _name, _args -> raise "call must never be invoked" end

  test "returns the first non-empty line" do
    assembled = "\n\nagent text\nmessage body\n"
    assert {:ok, "fake model: agent text"} = Fake.complete(assembled, never_call())
  end

  test "empty assembled" do
    assert {:ok, "fake model: "} = Fake.complete("", never_call())
  end

  test "call is never invoked" do
    assert {:ok, _} = Fake.complete("hello", never_call())
  end
end
