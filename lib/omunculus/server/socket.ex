defmodule Omunculus.Server.Socket do
  @moduledoc """
  Serves one project's HTTP entry on a Unix socket next to its store,
  `<store>.omunculus.sock`, which only the server's user can open.
  Requests on it act as the local principal, the one the direct CLI uses.
  The socket is bound inside a private directory and moved into place
  once its mode is set. It starts after the project runtime, which holds
  the store's lock, so a socket file left by an earlier server is removed.
  """

  use GenServer

  alias Omunculus.Config
  alias Omunculus.Server.Endpoint

  # sun_path holds 108 bytes, the terminating NUL included.
  @max_path 107

  @spec path(String.t()) :: String.t()
  def path(store), do: store <> ".omunculus.sock"

  def start_link({id, config_path, stream_key}),
    do: GenServer.start_link(__MODULE__, {id, config_path, stream_key})

  @impl true
  def init({id, config_path, stream_key}) do
    Process.flag(:trap_exit, true)

    endpoint = [local: id, projects: [id], stream_key: stream_key]

    with {:ok, config} <- Config.load(config_path),
         path = path(config.store.path),
         {:ok, listener} <- listen(path, endpoint) do
      {:ok, %{listener: listener, path: path}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp listen(path, endpoint) do
    staging = Path.join(Path.dirname(path), ".omunculus-" <> suffix())
    bound = Path.join(staging, "s")

    with :ok <- fits(path),
         :ok <- fits(bound),
         _ = File.rm(path),
         :ok <- File.mkdir(staging) do
      try do
        with :ok <- File.chmod(staging, 0o700),
             {:ok, listener} <-
               Bandit.start_link(
                 plug: {Endpoint, endpoint},
                 ip: {:local, bound},
                 port: 0,
                 startup_log: false
               ),
             :ok <- File.chmod(bound, 0o600),
             :ok <- File.rename(bound, path) do
          {:ok, listener}
        end
      after
        File.rm_rf(staging)
      end
    end
  end

  defp fits(path) when byte_size(path) <= @max_path, do: :ok
  defp fits(path), do: {:error, {:server, :socket_path_too_long, path}}

  defp suffix, do: Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  @impl true
  def handle_info({:EXIT, listener, reason}, %{listener: listener} = state),
    do: {:stop, reason, state}

  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.listener), do: Supervisor.stop(state.listener)
    File.rm(state.path)
    :ok
  end
end
