defmodule Omunculus.Model.AnthropicMessagesTest do
  use ExUnit.Case

  @moduletag :cargo

  alias Omunculus.{ExecutionPolicyFixtures, Fixtures}
  alias Omunculus.Model.AnthropicMessages
  alias Omunculus.OpenAIStub
  alias Omunculus.Tools.Out

  @assembled """
  You are the worker.

  ## Tools
  #{Out.tools_preamble()}
  - counter: increments and returns the total
  """

  @tools [
    %{name: "counter", description: "increments and returns the total", parameters: %{}}
  ]

  defp recorder do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    call = fn name, args -> Agent.get_and_update(agent, &{{:ok, ""}, &1 ++ [{name, args}]}) end
    {agent, call}
  end

  defp calls(agent), do: Agent.get(agent, & &1)

  setup do
    {:ok, stub} = OpenAIStub.start()
    on_exit(fn -> OpenAIStub.stop(stub) end)
    %{stub: stub, base_url: stub.base_url <> "/v1"}
  end

  test "tool_rounds: 1 calls the tool exactly once and returns the final content", %{
    stub: stub,
    base_url: base_url
  } do
    :ok = OpenAIStub.configure(%{base_url: String.trim_trailing(base_url, "/v1")}, tool_rounds: 1)
    model = AnthropicMessages.new(spec(base_url))
    {agent, call} = recorder()

    assert {:ok, "benchmark complete"} =
             model.(@assembled, @tools, call, fn _message -> :ok end, policy())

    assert calls(agent) == [{"counter", %{}}]

    assert {:ok, %{"last_tools" => [tool, executor]}} = OpenAIStub.stats(stub)
    assert tool["name"] == "counter"
    assert executor["name"] == "__omunculus_execute"
    assert tool["parameters"]["type"] == "object"
  end

  test "tool_rounds: 0 never calls the tool", %{base_url: base_url} do
    :ok = OpenAIStub.configure(%{base_url: String.trim_trailing(base_url, "/v1")}, tool_rounds: 0)
    model = AnthropicMessages.new(spec(base_url))
    {agent, call} = recorder()

    assert {:ok, "benchmark complete"} =
             model.(@assembled, @tools, call, fn _message -> :ok end, policy())

    assert calls(agent) == []
  end

  test "an unreachable base_url yields {:error, {:anthropic, _}}" do
    model = AnthropicMessages.new(spec("http://127.0.0.1:1"))
    {_agent, call} = recorder()

    assert {:error, {:anthropic, _reason}} =
             model.(@assembled, @tools, call, fn _message -> :ok end, policy())
  end

  test "records all model turns and executes tools", %{
    stub: stub,
    base_url: base_url
  } do
    :ok = OpenAIStub.configure(stub, tool_rounds: 1)
    dir = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(dir)

    Fixtures.write_config(dir, """
    [models.local]
    api = "anthropic-messages"
    url = "#{base_url}"
    model = "stub"
    timeout_ms = 120000

    [agents.concierge]
    depth = 0
    model = "local"
    text = "Count once."
    tools = ["counter"]
    """)

    {:ok, project} = Omunculus.Fixtures.open_project(dir)

    on_exit(fn ->
      Omunculus.Project.close(project)
      File.rm_rf!(dir)
    end)

    opening = %{prompt_id: nil, work_id: nil, request_id: nil, agent: nil, via: nil}
    assert {:ok, run} = Omunculus.Run.open(project, opening)
    assert {:ok, 1} = Omunculus.Store.view(project.conn, "counter", nil)
    assert {:ok, events} = Omunculus.Store.replay(project.conn, {:run, run.id})
    assert Enum.map(events, & &1.type) == ~w(start-run model tool model end-run)
    [first, last] = Enum.filter(events, &(&1.type == "model"))
    assert Jason.decode!(first.body)["content"] != []
    assert Jason.decode!(last.body)["content"] != []
  end

  defp spec(url, model \\ "stub") do
    %{"url" => url, "model" => model, "timeout_ms" => 120_000}
  end

  defp policy do
    ExecutionPolicyFixtures.policy(Application.app_dir(:omunculus, "priv"), network: "none")
  end
end
