defmodule Omunculus.Model.OpenAITest do
  use ExUnit.Case

  @moduletag :cargo

  alias Omunculus.{ExecutionPolicyFixtures, Fixtures}
  alias Omunculus.Model.OpenAI
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
    model = OpenAI.new(spec(base_url))
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
    model = OpenAI.new(spec(base_url))
    {agent, call} = recorder()

    assert {:ok, "benchmark complete"} =
             model.(@assembled, @tools, call, fn _message -> :ok end, policy())

    assert calls(agent) == []
  end

  test "an unreachable base_url yields {:error, {:openai, _}}" do
    model = OpenAI.new(spec("http://127.0.0.1:1"))
    {_agent, call} = recorder()

    assert {:error, {:openai, _reason}} =
             model.(@assembled, @tools, call, fn _message -> :ok end, policy())
  end

  for javascript <- [false, true] do
    test "records all model turns and executes tools (JavaScript: #{javascript})", %{
      stub: stub,
      base_url: base_url
    } do
      :ok = OpenAIStub.configure(stub, tool_rounds: 1, javascript: unquote(javascript))
      dir = Path.join(System.tmp_dir!(), Omunculus.Id.new())
      File.mkdir_p!(dir)

      Fixtures.write_config(dir, """
      [models.local]
      api = "openai-completions"
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
      assert Jason.decode!(first.body)["tool_calls"] != []
      assert Jason.decode!(last.body)["content"] == "benchmark complete"
    end
  end

  @tag cargo: false
  test "sends Bearer from credential" do
    {:ok, server} = start_header_server()

    model =
      OpenAI.new(%{
        "url" => "http://127.0.0.1:#{server.port}/v1",
        "model" => "stub",
        "timeout_ms" => 120_000,
        "credential" => %{"access" => "secret-token"}
      })

    {_agent, call} = recorder()

    assert {:ok, text} =
             model.("ping", [], call, fn _message -> :ok end, policy())

    assert text =~ "ok"
    assert_receive {:auth_header, "Bearer secret-token"}, 5_000
    Process.exit(server.pid, :kill)
  end

  defp start_header_server do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, listen} =
          :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

        {:ok, port} = :inet.port(listen)
        send(parent, {:ready, port})

        {:ok, socket} = :gen_tcp.accept(listen, 30_000)
        {:ok, packet} = :gen_tcp.recv(socket, 0, 30_000)
        packet = to_string(packet)

        auth =
          packet
          |> String.split("\r\n")
          |> Enum.find_value("", fn line ->
            case String.split(line, ": ", parts: 2) do
              [key, value] ->
                if String.downcase(key) == "authorization", do: value, else: false

              _ ->
                false
            end
          end)

        send(parent, {:auth_header, auth})

        body =
          Jason.encode!(%{
            "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
          })

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
        )

        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
      end)

    receive do
      {:ready, port} -> {:ok, %{pid: pid, port: port}}
    after
      5_000 -> flunk("header server did not start")
    end
  end

  @tag :local_model
  test "talks to a real local OpenAI-compatible server" do
    base_url = System.fetch_env!("OMUNCULUS_OPENAI_URL")
    model_name = System.fetch_env!("OMUNCULUS_OPENAI_MODEL")
    model = OpenAI.new(spec(base_url, model_name))
    {_agent, call} = recorder()

    assert {:ok, text} =
             model.("Responda apenas: pong", [], call, fn _message -> :ok end, policy())

    assert text =~ "pong"
  end

  defp spec(url, model \\ "stub") do
    %{"url" => url, "model" => model, "timeout_ms" => 120_000}
  end

  defp policy do
    ExecutionPolicyFixtures.policy(Application.app_dir(:omunculus, "priv"), network: "none")
  end
end
