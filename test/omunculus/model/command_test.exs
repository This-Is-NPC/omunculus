defmodule Omunculus.Model.CommandTest do
  use ExUnit.Case

  @moduletag :sandbox

  alias Omunculus.ExecutionPolicyFixtures
  alias Omunculus.Model.Command

  @bridge Path.expand("test/support/command_bridge.py", Path.join([__DIR__, "..", "..", ".."]))
  @assembled "You are the worker."
  @tools [%{name: "counter", description: "increments", parameters: %{}}]

  defp recorder do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    call = fn name, args -> Agent.get_and_update(agent, &{{:ok, "1"}, &1 ++ [{name, args}]}) end
    {agent, call}
  end

  defp calls(agent), do: Agent.get(agent, & &1)

  test "a bash/python bridge calls tools then returns text" do
    dir = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    policy =
      ExecutionPolicyFixtures.policy([dir, Path.dirname(@bridge)],
        limits: %{
          timeout_ms: 10_000,
          max_output_bytes: 65_536,
          max_concurrent: 4,
          max_queue: 4,
          queue_timeout_ms: 5_000
        }
      )

    model =
      Command.new(%{
        "command" => ["/usr/bin/python3", @bridge],
        "model" => "composer-2.5",
        "params" => %{}
      })

    {agent, call} = recorder()
    recorded = Agent.start_link(fn -> [] end) |> elem(1)
    record = fn message -> Agent.update(recorded, &(&1 ++ [message])) end

    assert {:ok, "benchmark complete"} = model.(@assembled, @tools, call, record, policy)
    assert calls(agent) == [{"counter", %{}}]
    messages = Agent.get(recorded, & &1)
    assert Enum.any?(messages, &(&1["type"] == "call"))
    assert Enum.any?(messages, &(&1["type"] == "text"))
  end
end
