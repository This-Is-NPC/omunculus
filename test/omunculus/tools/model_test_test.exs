defmodule Omunculus.Tools.ModelTestTest do
  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Fixtures}
  alias Omunculus.Tool.Catalog

  setup do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    %{dir: dir, path: Fixtures.config_path(dir)}
  end

  test "prints the reply of a saved model and how long it took", %{dir: dir} do
    Fixtures.use_model(dir, fn assembled, [], _call -> {:ok, "ok, I read: " <> assembled} end)

    assert {:ok, output} = CLI.run(["model_test", "--name", "scripted"], dir)

    assert %{"reply" => "ok, I read: This is a connection test." <> _, "ms" => ms} =
             Jason.decode!(output)

    assert is_integer(ms)
  end

  test "says why a model fails", %{dir: dir} do
    Fixtures.use_model(dir, fn _assembled, _tools, _call -> {:error, :refused} end)

    assert {:error, {:tool_failed, ":refused"}} =
             CLI.run(["model_test", "--name", "scripted"], dir)
  end

  test "tests a draft table and leaves the file as it is", %{dir: dir, path: path} do
    before = File.read!(path)

    draft =
      Jason.encode!(%{
        "api" => "openai-completions",
        "url" => "http://127.0.0.1:1/v1",
        "model" => "stub",
        "timeout_ms" => 1_000
      })

    assert {:error, {:tool_failed, reason}} =
             CLI.run(["model_test", "--name", "draft", "--value", draft], dir)

    assert reason =~ "openai"
    assert File.read!(path) == before
  end

  test "refuses a model it does not have and a command model", %{dir: dir} do
    assert {:error, {:tool_failed, "no model missing"}} =
             CLI.run(["model_test", "--name", "missing"], dir)

    command = Jason.encode!(%{"api" => "command", "command" => ["./model"], "model" => "m"})

    assert {:error, {:tool_failed, "a command model runs in the sandbox" <> _}} =
             CLI.run(["model_test", "--name", "local", "--value", command], dir)
  end

  test "the builtin catalog discovers model_test with triggers == [\"cli\"]" do
    assert %{"model_test" => manifest} = Catalog.unconfigured()
    assert manifest.triggers == ["cli"]
  end
end
