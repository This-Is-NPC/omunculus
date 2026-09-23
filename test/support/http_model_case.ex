defmodule Omunculus.HttpModelCase do
  @moduledoc """
  The tests every HTTP model adapter shares against the Rust OpenAI stub:
  one tool round, no tool round and an unreachable url. `use` it with the
  adapter `module` and the `error` tag of a failed request; `run_counter/2`
  opens a run whose agent counts once through the adapter named by `api`.
  """

  use ExUnit.CaseTemplate

  alias Omunculus.{ExecutionPolicyFixtures, Fixtures, OpenAIStub, Project, Run, Store}
  alias Omunculus.Tools.Out

  using opts do
    quote do
      @moduletag :cargo

      import Omunculus.HttpModelCase

      alias Omunculus.OpenAIStub

      @adapter unquote(Keyword.fetch!(opts, :module))
      @error unquote(Keyword.fetch!(opts, :error))

      test "tool_rounds: 1 calls the tool exactly once and returns the final content", %{
        stub: stub,
        base_url: base_url
      } do
        :ok =
          OpenAIStub.configure(%{base_url: String.trim_trailing(base_url, "/v1")}, tool_rounds: 1)

        {agent, call} = recorder()

        assert {:ok, "benchmark complete"} = call_model(@adapter, base_url, call)
        assert calls(agent) == [{"counter", %{}}]

        assert {:ok, %{"last_tools" => [tool, executor]}} = OpenAIStub.stats(stub)
        assert tool["name"] == "counter"
        assert executor["name"] == "__omunculus_execute"
        assert tool["parameters"]["type"] == "object"
      end

      test "tool_rounds: 0 never calls the tool", %{base_url: base_url} do
        :ok =
          OpenAIStub.configure(%{base_url: String.trim_trailing(base_url, "/v1")}, tool_rounds: 0)

        {agent, call} = recorder()

        assert {:ok, "benchmark complete"} = call_model(@adapter, base_url, call)
        assert calls(agent) == []
      end

      test "an unreachable base_url yields {:error, {#{inspect(@error)}, _}}" do
        {_agent, call} = recorder()

        assert {:error, {@error, _reason}} = call_model(@adapter, "http://127.0.0.1:1", call)
      end
    end
  end

  setup do
    {:ok, stub} = OpenAIStub.start()
    on_exit(fn -> OpenAIStub.stop(stub) end)
    %{stub: stub, base_url: stub.base_url <> "/v1"}
  end

  @spec assembled() :: String.t()
  def assembled do
    """
    You are the worker.

    ## Tools
    #{Out.tools_preamble()}
    - counter: increments and returns the total
    """
  end

  @spec tools() :: [map]
  def tools,
    do: [%{name: "counter", description: "increments and returns the total", parameters: %{}}]

  @doc "A tool call function that answers `{:ok, \"\"}` and records each call in an agent."
  @spec recorder() :: {pid, fun}
  def recorder do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    call = fn name, args -> Agent.get_and_update(agent, &{{:ok, ""}, &1 ++ [{name, args}]}) end
    {agent, call}
  end

  @spec calls(pid) :: [{String.t(), map}]
  def calls(agent), do: Agent.get(agent, & &1)

  @spec spec(String.t(), String.t()) :: map
  def spec(url, model \\ "stub"), do: %{"url" => url, "model" => model, "timeout_ms" => 120_000}

  @spec policy() :: Omunculus.Execution.Policy.t()
  def policy,
    do: ExecutionPolicyFixtures.policy(Application.app_dir(:omunculus, "priv"), network: "none")

  @doc "Calls the adapter `module` at `url` with the shared prompt and tools."
  @spec call_model(module, String.t(), fun) :: {:ok, String.t()} | {:error, term}
  def call_model(module, url, call),
    do: module.new(spec(url)).(assembled(), tools(), call, fn _message -> :ok end, policy())

  @doc """
  Opens one run in a fresh project whose agent counts once through a model
  of the adapter `api` at `base_url`, and returns the run's events.
  """
  @spec run_counter(String.t(), String.t()) :: [map]
  def run_counter(api, base_url) do
    dir = Fixtures.tmp_dir()

    Fixtures.write_config(dir, """
    [models.local]
    api = "#{api}"
    url = "#{base_url}"
    model = "stub"
    timeout_ms = 120000

    [agents.concierge]
    depth = 0
    model = "local"
    text = "Count once."
    tools = ["counter"]
    """)

    project = Fixtures.open_project(dir)

    try do
      {:ok, run} = Run.open(project, Fixtures.opening(nil))
      {:ok, 1} = Store.view(project.conn, "counter", nil)
      {:ok, events} = Store.replay(project.conn, {:run, run.id})
      events
    after
      Project.close(project)
    end
  end
end
