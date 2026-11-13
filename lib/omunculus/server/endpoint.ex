defmodule Omunculus.Server.Endpoint do
  @moduledoc "Passes the server's runtime configuration into the HTTP router."

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    conn
    |> Plug.Conn.assign(:server_opts, opts)
    |> Omunculus.Server.Router.call(Omunculus.Server.Router.init([]))
  end
end
