defmodule Omunculus.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "dispatch --help exits 0" do
    {code, out} =
      with_io(fn ->
        Omunculus.CLI.dispatch(["--help"], %{})
      end)

    assert code == 0
    assert out =~ "Usage: omunculus"
  end

  test "dispatch --version prints the version" do
    {code, out} =
      with_io(fn ->
        Omunculus.CLI.dispatch(["--version"], %{})
      end)

    assert code == 0
    assert String.trim(out) == Omunculus.version()
  end

  test "dispatch with an unknown flag exits 2" do
    {code, err} =
      with_io(:stderr, fn ->
        Omunculus.CLI.dispatch(["--nope"], %{})
      end)

    assert code == 2
    assert err =~ "unexpected argument '--nope'"
  end

  test "run against a fixture with a stubbed completions server writes a file" do
    tmp = Path.join(System.tmp_dir!(), "omunculus-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "seed.txt"), "seed\n")
    bypass = Bypass.open()

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(raw)
      messages = payload["messages"]
      has_tool_result? = Enum.any?(messages, &(&1["role"] == "tool"))

      body =
        if has_tool_result? do
          %{
            "choices" => [
              %{
                "message" => %{
                  "role" => "assistant",
                  "content" => Jason.encode!(%{completed: true, comment: "wrote README"})
                }
              }
            ],
            "usage" => %{"total_tokens" => 2}
          }
        else
          %{
            "choices" => [
              %{
                "message" => %{
                  "role" => "assistant",
                  "content" => nil,
                  "tool_calls" => [
                    %{
                      "id" => "call_1",
                      "type" => "function",
                      "function" => %{
                        "name" => "write",
                        "arguments" =>
                          Jason.encode!(%{
                            "path" => "README.md",
                            "content" => "hello from omunculus\n"
                          })
                      }
                    }
                  ]
                }
              }
            ],
            "usage" => %{"total_tokens" => 1}
          }
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    env = %{
      "OMUNCULUS_BASE_URL" => "http://127.0.0.1:#{bypass.port}/v1",
      "OMUNCULUS_MODEL" => "fake-model",
      "OMUNCULUS_API_KEY" => "unused"
    }

    {code, out, _progress} =
      capture_cli(fn ->
        Omunculus.CLI.dispatch(["run", tmp, "add a README"], env)
      end)

    assert code == 0
    assert String.trim(out) == "wrote README"
    assert File.read!(Path.join(tmp, "README.md")) == "hello from omunculus\n"
    File.rm_rf(tmp)
  end

  test "run loads .env from the target directory without replacing exported values" do
    tmp = Path.join(System.tmp_dir!(), "omunculus-dotenv-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw)["model"] == "exported-model"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "choices" => [
            %{"message" => %{"content" => Jason.encode!(%{completed: true, comment: "done"})}}
          ]
        })
      )
    end)

    File.write!(
      Path.join(tmp, ".env"),
      "OMUNCULUS_BASE_URL=http://127.0.0.1:#{bypass.port}/v1\nOMUNCULUS_MODEL=from-file\n"
    )

    env = %{"OMUNCULUS_MODEL" => "exported-model"}

    {code, out, _progress} =
      capture_cli(fn ->
        Omunculus.CLI.dispatch(["run", tmp, "summarize"], env)
      end)

    assert code == 0
    assert String.trim(out) == "done"
    File.rm_rf(tmp)
  end

  test "monkey-job sends no tool catalog when --tools is omitted" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(raw)
      refute Map.has_key?(payload, "tools")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "choices" => [
            %{"message" => %{"content" => Jason.encode!(%{completed: true, comment: "1 2 3"})}}
          ]
        })
      )
    end)

    env = %{
      "OMUNCULUS_BASE_URL" => "http://127.0.0.1:#{bypass.port}/v1",
      "OMUNCULUS_MODEL" => "fake-model"
    }

    {code, out, progress} =
      capture_cli(fn -> Omunculus.CLI.dispatch(["monkey-job", "count to 3"], env) end)

    assert code == 0
    assert Jason.decode!(String.trim(out))["comment"] == "1 2 3"
    assert progress =~ "│ Model: fake-model · Tools: 0"
    assert progress =~ "│ Exposed tools     │ none"
  end

  test "monkey-job exposes counter and delays its result" do
    bypass = Bypass.open()
    parent = self()

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(raw)
      messages = payload["messages"]
      tool_result = Enum.find(messages, &(&1["role"] == "tool"))

      body =
        if tool_result do
          send(parent, {:tool_result, tool_result["content"]})

          %{
            "choices" => [
              %{"message" => %{"content" => Jason.encode!(%{completed: true, comment: "done"})}}
            ]
          }
        else
          assert get_in(payload, ["tools", Access.at(0), "function", "name"]) == "counter"

          %{
            "choices" => [
              %{
                "message" => %{
                  "content" => nil,
                  "tool_calls" => [
                    %{
                      "id" => "counter_1",
                      "type" => "function",
                      "function" => %{"name" => "counter", "arguments" => "{}"}
                    }
                  ]
                }
              }
            ]
          }
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    env = %{
      "OMUNCULUS_BASE_URL" => "http://127.0.0.1:#{bypass.port}/v1",
      "OMUNCULUS_MODEL" => "fake-model"
    }

    {elapsed_us, {code, out, progress}} =
      :timer.tc(fn ->
        capture_cli(fn ->
          Omunculus.CLI.dispatch(
            [
              "monkey-job",
              "count to 2",
              "--tools",
              "counter",
              "--delay",
              "20ms",
              "--increment",
              "2"
            ],
            env
          )
        end)
      end)

    assert code == 0
    assert Jason.decode!(String.trim(out))["comment"] == "done"
    assert_receive {:tool_result, "Counter value: 2"}
    assert elapsed_us >= 20_000
    assert progress =~ "Tool · Counter · 0 -> 2"
    assert progress =~ "│ Counter value     │ 2"
    assert progress =~ "│ Counter increment │ 2"
  end

  test "benchmark passes dotenv environment into real provider config without a request" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "omunculus-benchmark-dotenv-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, ".env"), "BENCHMARK_API=unsupported\n")

    File.write!(
      Path.join(tmp, "omunculus.toml"),
      "[chat]\napi = \"${BENCHMARK_API}\"\nmodel = \"model\"\nbase_url = \"unused\"\n"
    )

    {code, _out, progress} =
      capture_cli(fn ->
        File.cd!(tmp, fn ->
          Omunculus.CLI.dispatch(
            ["benchmark", "--max-agents", "1", "--no-live", "--provider", "real"],
            %{}
          )
        end)
      end)

    assert code == 1
    assert progress =~ ~s(error: unsupported chat api "unsupported")
    File.rm_rf(tmp)
  end

  defp capture_cli(fun) do
    progress =
      capture_io(:stderr, fn ->
        result = with_io(fun)
        Process.put(:cli_result, result)
      end)

    {code, output} = Process.delete(:cli_result)

    {code, output, progress}
  end
end
