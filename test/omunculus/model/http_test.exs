defmodule Omunculus.Model.HTTPTest do
  use ExUnit.Case, async: true

  alias Omunculus.Model.HTTP
  alias Omunculus.Tools.Out

  @tool %{name: "read", description: "Read a file", parameters: %{}}

  test "the executor follows the run's tools only under code_mode" do
    assert HTTP.tools(%{code_mode: false}, [@tool], & &1.name) == ["read"]
    assert HTTP.tools(%{code_mode: true}, [@tool], & &1.name) == ["read", "__omunculus_execute"]
  end

  test "an empty schema becomes an empty object schema" do
    assert HTTP.parameters_schema(%{}) == %{type: "object", properties: %{}}
    assert HTTP.parameters_schema(%{type: "object"}) == %{type: "object"}
  end

  test "a tool call reaches call with its decoded arguments" do
    call = fn name, args -> {:ok, "#{name} #{args["path"]}"} end

    assert HTTP.run("read", ~s({"path":"a"}), call, [], nil) == {:ok, "read a"}
    assert HTTP.run("read", "[1]", call, [], nil) == {:error, Out.invalid_arguments()}
  end

  test "headers come as a list or a table" do
    assert HTTP.headers_list(nil) == []
    assert HTTP.headers_list([{"x-a", "1"}]) == [{"x-a", "1"}]
    assert HTTP.headers_list(%{"x-a" => "1"}) == [{"x-a", "1"}]
  end
end
