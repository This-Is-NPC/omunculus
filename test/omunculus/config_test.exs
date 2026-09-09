defmodule Omunculus.ConfigTest do
  use ExUnit.Case, async: true

  alias Omunculus.Config

  @root Path.expand("../..", __DIR__)

  test "explicit config selects the local chat provider" do
    assert {:ok, config} =
             Config.load(
               cwd: @root,
               config_file: Path.join(@root, "presets/local.toml")
             )

    assert {:ok, session} = Config.resolve(config, %{})
    assert session.chat.base_url == "http://192.168.0.200:1234/v1"
    assert session.chat.model == "qwen/qwen3.5-9b"
    assert session.chat.auth == "none"
    assert session.chat.timeout_ms == "infinity"
    assert session.output.timestamp_format == "%d/%m/%Y %H:%M:%S"
  end

  test "chat timeout is a positive transport deadline or infinity" do
    for value <- [0, -1, "120000", false] do
      config = put_in(Config.empty(), [:chat, :timeout_ms], value)
      assert {:error, {:invalid_chat_timeout, ^value}} = Config.check(config)
    end

    assert {:ok, _} = Config.check(put_in(Config.empty(), [:chat, :timeout_ms], 250))
  end

  test "explicit config selects the cloud chat provider" do
    assert {:ok, config} =
             Config.load(
               cwd: @root,
               config_file: Path.join(@root, "presets/cloud.toml"),
               env: %{"OPENROUTER_API_KEY" => "secret-value"}
             )

    assert {:ok, session} = Config.resolve(config, %{})
    assert session.chat.base_url == "https://openrouter.ai/api/v1"
    assert session.chat.model == "deepseek/deepseek-v4-flash-0731"
    assert session.chat.auth == "api_key"
    assert session.chat.api_key == "secret-value"
    assert session.output.timestamp_format == "%d/%m/%Y %H:%M:%S"
  end

  test "rejects an invalid timestamp format during resolution" do
    path =
      Path.join(System.tmp_dir!(), "omunculus-config-#{System.unique_integer([:positive])}.toml")

    File.write!(path, "[output]\ntimestamp_format = \"%Q\"\n")

    assert {:ok, config} = Config.load(cwd: @root, config_file: path)

    assert {:error, {:invalid_timestamp_format, "%Q"}} = Config.resolve(config, %{})
    File.rm!(path)
  end

  test "expands exact environment references recursively" do
    path =
      Path.join(
        System.tmp_dir!(),
        "omunculus-env-config-#{System.unique_integer([:positive])}.toml"
      )

    File.write!(
      path,
      "[chat]\nbase_url = \"${TEST_BASE_URL}\"\nmodel = \"${TEST_MODEL}\"\napi_key = \"${TEST_KEY}\"\n"
    )

    env = %{
      "TEST_BASE_URL" => "https://example.test/v1",
      "TEST_MODEL" => "test-model",
      "TEST_KEY" => "test-secret"
    }

    assert {:ok, config} = Config.load(cwd: @root, config_file: path, env: env)
    assert config.chat.base_url == "https://example.test/v1"
    assert config.chat.model == "test-model"
    assert config.chat.api_key == "test-secret"
    File.rm!(path)
  end

  test "config_file overlays project omunculus.toml" do
    dir = Path.join(System.tmp_dir!(), "omunculus-layer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    base = Path.join(dir, "omunculus.toml")
    overlay = Path.join(dir, "overlay.toml")

    File.write!(base, """
    [profiles.count]
    mode = "deny"
    granted = ["counter"]
    """)

    File.write!(overlay, """
    [interceptors.audit]
    events = ["task.requested"]
    module = "Omunculus.Interceptors.Audit"
    """)

    assert {:ok, config} = Config.load(cwd: dir, config_file: overlay, env: %{})

    assert %{"count" => %{policy: %{"granted" => ["counter"]}}} = config.presets
    assert Enum.any?(config.interceptors, &(&1.name == "audit"))

    File.rm_rf!(dir)
  end

  test "rejects a missing environment reference without exposing config values" do
    path =
      Path.join(
        System.tmp_dir!(),
        "omunculus-missing-env-#{System.unique_integer([:positive])}.toml"
      )

    File.write!(path, "[chat]\napi_key = \"${MISSING_SECRET}\"\n")

    assert {:error, {:missing_config_env, "MISSING_SECRET"}} =
             Config.load(cwd: @root, config_file: path, env: %{})

    File.rm!(path)
  end
end
