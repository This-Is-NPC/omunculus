defmodule Omunculus.Model.ArgumentsTest do
  use ExUnit.Case, async: true

  alias Omunculus.Model.Arguments
  alias Omunculus.Tools.Out

  test "an object, its JSON text or nothing are the call's arguments" do
    assert Arguments.decode(%{"path" => "a"}) == {:ok, %{"path" => "a"}}
    assert Arguments.decode(~s({"path":"a"})) == {:ok, %{"path" => "a"}}
    assert Arguments.decode("") == {:ok, %{}}
    assert Arguments.decode(nil) == {:ok, %{}}
  end

  test "anything else is told to the model" do
    for arguments <- ["\nરસassistant to=functions.read", "[1]", 3] do
      assert Arguments.decode(arguments) == {:error, Out.invalid_arguments()}
    end
  end
end
