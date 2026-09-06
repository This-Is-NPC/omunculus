defmodule Omunculus.DotenvTest do
  use ExUnit.Case, async: true

  alias Omunculus.Dotenv

  test "parses assignments, exports, quotes, and comments" do
    body = """
    # OpenRouter
    OMUNCULUS_API_KEY=sk-test
    export OMUNCULUS_MODEL="qwen/qwen3.5-9b"
    OMUNCULUS_BASE_URL='https://openrouter.ai/api/v1'
    OMUNCULUS_MAX_TURNS=4 # keep the run short
    """

    assert {:ok, env} = Dotenv.parse(body)
    assert env["OMUNCULUS_API_KEY"] == "sk-test"
    assert env["OMUNCULUS_MODEL"] == "qwen/qwen3.5-9b"
    assert env["OMUNCULUS_BASE_URL"] == "https://openrouter.ai/api/v1"
    assert env["OMUNCULUS_MAX_TURNS"] == "4"
  end

  test "reports the line number of malformed entries" do
    assert {:error, {:invalid_dotenv, 2}} = Dotenv.parse("VALID=yes\nnot valid\n")
  end

  test "a missing file produces an empty environment" do
    path = Path.join(System.tmp_dir!(), "missing-dotenv-#{System.unique_integer([:positive])}")
    assert {:ok, %{}} = Dotenv.load(path)
  end
end
