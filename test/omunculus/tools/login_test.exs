defmodule Omunculus.Tools.LoginTest do
  use ExUnit.Case, async: false

  alias Omunculus.{CLI, Config, Fixtures, Id}

  setup do
    dir = Path.join(System.tmp_dir!(), Id.new())
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write(dir, extra) do
    Fixtures.write_config(dir, extra)
    Fixtures.config_path(dir)
  end

  test "cli login stores an api key", %{dir: dir} do
    write(dir, """
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

    assert {:ok, output} = CLI.run(["login", "--provider", "local", "--key", "abc123"], dir)
    assert output =~ "logged in to local"

    store = Jason.decode!(File.read!(Path.join(dir, ".auth.json")))
    assert store["local"]["key"] == "abc123"
    assert {:ok, config} = Config.load(Fixtures.config_path(dir))

    assert {:ok, %{access: "abc123", expires_at: nil}} =
             Omunculus.Auth.credential(config, "local")
  end

  test "oauth login with redirect_url exchanges against a local token server", %{dir: dir} do
    {:ok, server} = start_token_server()

    path =
      write(dir, """
      [auth]
      store = ".auth.json"

      [auth.oauth]
      kind = "oauth-code"
      authorize_url = "http://localhost/authorize"
      token_url = "http://127.0.0.1:#{server.port}/token"
      client_id = "client"
      scopes = ["read"]
      pkce = false

      [auth.oauth.callback]
      host = "127.0.0.1"
      port = 9876
      path = "/cb"

      [auth.oauth.credential]
      access = "access_token"
      expires = "expires_in"
      refresh = "refresh_token"

      [models.fake]
      api = "module"
      module = "Omunculus.Model.Fake"

      [agents.concierge]
      depth = 0
      model = "fake"
      text = "hi"
      """)

    redirect = "http://127.0.0.1:9876/cb?code=abc"

    assert {:ok, output} =
             CLI.run(
               ["login", "--provider", "oauth", "--redirect_url", redirect],
               dir
             )

    assert output =~ "logged in to oauth"
    store = Jason.decode!(File.read!(Path.join(dir, ".auth.json")))
    assert store["oauth"]["access"] == "fresh-token"
    assert {:ok, config} = Config.load(path)
    assert {:ok, %{access: "fresh-token"}} = Omunculus.Auth.credential(config, "oauth")
    Process.exit(server.pid, :kill)
  end

  defp start_token_server do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, listen} =
          :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

        {:ok, port} = :inet.port(listen)
        send(parent, {:ready, port})

        {:ok, socket} = :gen_tcp.accept(listen, 30_000)
        {:ok, _packet} = :gen_tcp.recv(socket, 0, 30_000)

        body = Jason.encode!(%{"access_token" => "fresh-token", "expires_in" => 3600})

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
      5_000 -> flunk("token server did not start")
    end
  end
end
