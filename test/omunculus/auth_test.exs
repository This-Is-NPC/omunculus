defmodule Omunculus.AuthTest do
  use ExUnit.Case, async: false

  alias Omunculus.{Auth, Config, Fixtures, Id}

  setup do
    dir = Path.join(System.tmp_dir!(), Id.new())
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp load(dir, extra) do
    Fixtures.write_config(dir, extra)
    Config.load(Fixtures.config_path(dir))
  end

  defp auth_toml(store, providers) do
    """
    [auth]
    store = "#{store}"

    #{providers}

    [models.fake]
    api = "module"
    module = "Omunculus.Model.Fake"

    [agents.concierge]
    depth = 0
    model = "fake"
    text = "hi"
    """
  end

  test "api_key resolves $VAR", %{dir: dir} do
    System.put_env("OMUNCULUS_TEST_KEY", "secret-from-env")

    assert {:ok, config} =
             load(
               dir,
               auth_toml(
                 ".auth.json",
                 """
                 [auth.env]
                 kind = "api_key"
                 key = "$OMUNCULUS_TEST_KEY"
                 """
               )
             )

    assert {:ok, %{access: "secret-from-env", expires_at: nil}} =
             Auth.credential(config, "env")
  after
    System.delete_env("OMUNCULUS_TEST_KEY")
  end

  test "api_key empty returns nil", %{dir: dir} do
    assert {:ok, config} =
             load(
               dir,
               auth_toml(
                 ".auth.json",
                 """
                 [auth.empty]
                 kind = "api_key"
                 key = ""
                 """
               )
             )

    assert {:ok, nil} = Auth.credential(config, "empty")
  end

  test "!cmd is cached in the process dictionary", %{dir: dir} do
    script = Path.join(dir, "counter.sh")
    count = Path.join(dir, ".count")

    File.write!(
      script,
      """
      #!/bin/sh
      n=0
      [ -f #{count} ] && n=$(cat #{count})
      n=$((n+1))
      echo $n > #{count}
      echo $n
      """
    )

    File.chmod!(script, 0o755)

    assert {:ok, config} =
             load(
               dir,
               auth_toml(
                 ".auth.json",
                 """
                 [auth.cmd]
                 kind = "api_key"
                 key = "!#{script}"
                 """
               )
             )

    assert {:ok, %{access: "1"}} = Auth.credential(config, "cmd")
    assert {:ok, %{access: "1"}} = Auth.credential(config, "cmd")
    assert String.trim(File.read!(count)) == "1"
  end

  test "oauth not_logged_in when store is missing", %{dir: dir} do
    assert {:ok, config} =
             load(
               dir,
               auth_toml(
                 ".auth.json",
                 """
                 [auth.oauth]
                 kind = "oauth-code"
                 authorize_url = "http://localhost/authorize"
                 token_url = "http://localhost/token"
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
                 """
               )
             )

    assert {:error, {:auth, :not_logged_in, "oauth"}} = Auth.credential(config, "oauth")
  end

  test "put writes store mode 0600 and logout deletes", %{dir: dir} do
    assert {:ok, config} =
             load(
               dir,
               auth_toml(
                 ".auth.json",
                 """
                 [auth.oauth]
                 kind = "oauth-code"
                 authorize_url = "http://localhost/authorize"
                 token_url = "http://localhost/token"
                 client_id = "client"
                 scopes = ["read"]
                 pkce = false

                 [auth.oauth.callback]
                 host = "127.0.0.1"
                 port = 9876
                 path = "/cb"

                 [auth.oauth.credential]
                 access = "access_token"
                 expires = "never"
                 """
               )
             )

    record = %{
      "type" => "oauth",
      "access" => "token",
      "expires_at" => "never"
    }

    assert :ok = Auth.put(config, "oauth", record)
    store = Path.join(dir, ".auth.json")
    assert File.regular?(store)
    assert File.stat!(store).mode |> rem(0o1000) == 0o600

    assert {:ok, %{access: "token", expires_at: "never"}} = Auth.credential(config, "oauth")
    assert :ok = Auth.delete(config, "oauth")
    assert {:error, {:auth, :not_logged_in, "oauth"}} = Auth.credential(config, "oauth")
  end

  test "expired oauth refreshes against a local token server", %{dir: dir} do
    {:ok, server} = start_token_server()

    assert {:ok, config} =
             load(
               dir,
               auth_toml(
                 ".auth.json",
                 """
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
                 """
               )
             )

    expired =
      DateTime.utc_now(:second)
      |> DateTime.add(-60, :second)
      |> DateTime.to_iso8601()

    assert :ok =
             Auth.put(config, "oauth", %{
               "type" => "oauth",
               "access" => "old",
               "refresh" => "refresh-me",
               "expires_at" => expired
             })

    assert {:ok, %{access: "fresh", expires_at: expires_at}} = Auth.credential(config, "oauth")
    assert is_binary(expires_at)
    assert expires_at != expired

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

        :gen_tcp.send(
          socket,
          response(200, Jason.encode!(%{"access_token" => "fresh", "expires_in" => 3600}))
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

  defp response(status, body) do
    "HTTP/1.1 #{status} OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
  end
end
