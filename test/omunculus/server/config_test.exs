defmodule Omunculus.Server.ConfigTest do
  use ExUnit.Case, async: true

  alias Omunculus.Fixtures
  alias Omunculus.Server.Config

  @limits """
  max_concurrent = 4
  max_queue = 64
  queue_timeout_ms = 30000
  max_connections = 8
  """

  @auth """
  [auth]
  issuer = "idp"
  audience = "omunculus"
  algorithm = "RS256"
  public_key = "public.pem"
  """

  setup do
    dir = Fixtures.tmp_dir()
    File.write!(Path.join(dir, "omunculus.toml"), "")
    File.write!(Path.join(dir, "public.pem"), "")
    %{dir: dir}
  end

  defp load(dir, server, rest \\ "") do
    path = Path.join(dir, "server.toml")

    File.write!(path, """
    [server]
    #{server}
    #{rest}
    [projects.alpha]
    config = "omunculus.toml"
    """)

    Config.load(path)
  end

  test "without host and port there is no TCP listener and no [auth]", %{dir: dir} do
    assert {:ok, %Config{http: nil, auth: nil, projects: %{"alpha" => _}}} = load(dir, @limits)
  end

  test "host and port come with [auth]", %{dir: dir} do
    listener = @limits <> ~s(host = "127.0.0.1"\nport = 4000\n)

    assert {:ok, %Config{http: %{host: {127, 0, 0, 1}, port: 4000}, auth: %{issuer: "idp"}}} =
             load(dir, listener, @auth)

    assert {:error, {:server, :missing_auth}} = load(dir, listener)
  end

  test "[auth] without a listener and a host without a port are refused", %{dir: dir} do
    assert {:error, {:server, :auth_without_listener}} = load(dir, @limits, @auth)

    assert {:error, {:server, :invalid_listener}} =
             load(dir, @limits <> ~s(host = "127.0.0.1"\n), @auth)
  end
end
