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
  rescue
    Plug.Parsers.ParseError -> json_error(conn, 400, "invalid")
    Plug.Parsers.UnsupportedMediaTypeError -> json_error(conn, 415, "unsupported_media_type")
  end

  defp json_error(conn, status, code) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(%{error: code}))
  end
end
