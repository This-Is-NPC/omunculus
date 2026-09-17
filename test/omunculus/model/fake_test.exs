defmodule Omunculus.Model.FakeTest do
  use ExUnit.Case, async: true

  alias Omunculus.Model.Fake

  defp never_call, do: fn _name, _args -> raise "call must never be invoked" end

  defp complete(assembled, tools \\ [], call \\ never_call()) do
    Fake.new(%{}).(assembled, tools, call, fn _text -> :ok end, nil)
  end

  test "returns the first non-empty line" do
    assembled = "\n\nagent text\nmessage body\n"
    assert {:ok, "fake model: agent text"} = complete(assembled)
  end

  test "empty assembled" do
    assert {:ok, "fake model: "} = complete("")
  end

  test "call is never invoked" do
    assert {:ok, _} = complete("hello")
  end
end
