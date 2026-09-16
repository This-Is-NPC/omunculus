defmodule Omunculus.Model.OpenAITest do
  use ExUnit.Case

  @moduletag :cargo

  alias Omunculus.Model.OpenAI
  alias Omunculus.OpenAIStub

  @assembled """
  Você é o worker.

  ## Tools
  As tools estão em `tools.*`.
  - counter: incrementa e devolve o total
  """

  defp recorder do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    call = fn name, args -> Agent.get_and_update(agent, &{{:ok, ""}, &1 ++ [{name, args}]}) end
    {agent, call}
  end

  defp calls(agent), do: Agent.get(agent, & &1)

  setup do
    {:ok, stub} = OpenAIStub.start()
    on_exit(fn -> OpenAIStub.stop(stub) end)
    %{base_url: stub.base_url <> "/v1"}
  end

  test "tool_rounds: 1 calls the tool exactly once and returns the final content", %{
    base_url: base_url
  } do
    :ok = OpenAIStub.configure(%{base_url: String.trim_trailing(base_url, "/v1")}, tool_rounds: 1)
    model = OpenAI.new(base_url, "stub")
    {agent, call} = recorder()

    assert {:ok, "benchmark complete"} = model.(@assembled, call)
    assert calls(agent) == [{"counter", %{}}]
  end

  test "tool_rounds: 0 never calls the tool", %{base_url: base_url} do
    :ok = OpenAIStub.configure(%{base_url: String.trim_trailing(base_url, "/v1")}, tool_rounds: 0)
    model = OpenAI.new(base_url, "stub")
    {agent, call} = recorder()

    assert {:ok, "benchmark complete"} = model.(@assembled, call)
    assert calls(agent) == []
  end

  test "an unreachable base_url yields {:error, {:openai, _}}" do
    model = OpenAI.new("http://127.0.0.1:1", "stub")
    {_agent, call} = recorder()

    assert {:error, {:openai, _reason}} = model.(@assembled, call)
  end

  @tag :local_model
  test "talks to a real local OpenAI-compatible server" do
    base_url = System.fetch_env!("OMUNCULUS_OPENAI_URL")
    model_name = System.fetch_env!("OMUNCULUS_OPENAI_MODEL")
    model = OpenAI.new(base_url, model_name)
    {_agent, call} = recorder()

    assert {:ok, text} = model.("Responda apenas: pong", call)
    assert text =~ "pong"
  end
end
