defmodule Omunculus.Tools.LogoutTest do
  use ExUnit.Case, async: false

  alias Omunculus.{CLI, Config, Fixtures, Id}

  setup do
    dir = Path.join(System.tmp_dir!(), Id.new())
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "cli logout removes stored credentials", %{dir: dir} do
    Fixtures.write_config(dir, """
    [auth]
    store = ".auth.json"

    [auth.local]
    kind = "api_key"
    key = ""

    [models.fake]
    api = "module"
    module = "Omunculus.Model.Fake"

    [agents.concierge]
    depth = 0
    model = "fake"
    text = "hi"
    """)

    assert {:ok, _} = CLI.run(["login", "--provider", "local", "--key", "abc123"], dir)
    assert {:ok, output} = CLI.run(["logout", "--provider", "local"], dir)
    assert output =~ "logged out of local"

    path = Fixtures.config_path(dir)
    assert {:ok, config} = Config.load(path)
    store = Path.join(dir, ".auth.json")
    refute Map.has_key?(Jason.decode!(File.read!(store)), "local")
    assert {:ok, nil} = Omunculus.Auth.credential(config, "local")
  end
end
