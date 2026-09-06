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
    assert session.chat.base_url == "http://127.0.0.1:52625/v1"
    assert session.chat.model == "qwen3.5:4b"
    assert session.chat.auth == "none"
    assert session.output.timestamp_format == "%d/%m/%Y %H:%M:%S"
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
    assert session.chat.model == "google/gemma-4-31b-it:free"
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
