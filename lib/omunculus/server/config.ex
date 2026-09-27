defmodule Omunculus.Server.Config do
  @moduledoc "Loads the server's TOML registry, listener and token verifier."

  @enforce_keys [
    :host,
    :port,
    :limits,
    :max_connections,
    :projects,
    :issuer,
    :audience,
    :algorithm,
    :public_key
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          host: :inet.ip_address(),
          port: pos_integer,
          limits: map,
          max_connections: pos_integer,
          projects: %{String.t() => String.t()},
          issuer: String.t(),
          audience: String.t(),
          algorithm: String.t(),
          public_key: String.t()
        }

  @spec load(String.t()) :: {:ok, %__MODULE__{}} | {:error, term}
  def load(path) do
    with true <- File.regular?(path) || {:error, {:server, :missing, path}},
         {:ok, data} <- Toml.decode_file(path),
         :ok <- keys(data, ~w(server auth projects)),
         {:ok, listener} <- listener(data["server"]),
         {:ok, auth} <- auth(data["auth"], Path.dirname(Path.expand(path))),
         {:ok, projects} <- projects(data["projects"], Path.dirname(Path.expand(path))) do
      {:ok, struct!(__MODULE__, Map.merge(listener, Map.merge(auth, %{projects: projects})))}
    end
  end

  defp listener(data) when is_map(data) do
    with :ok <-
           keys(data, ~w(host port max_concurrent max_queue queue_timeout_ms max_connections)),
         host when is_binary(host) <- data["host"],
         {:ok, ip} <- parse_ip(host),
         port when is_integer(port) and port in 1..65_535 <- data["port"],
         concurrent when is_integer(concurrent) and concurrent > 0 <- data["max_concurrent"],
         queue when is_integer(queue) and queue >= 0 <- data["max_queue"],
         timeout when is_integer(timeout) and timeout > 0 <- data["queue_timeout_ms"],
         connections when is_integer(connections) and connections > 0 <- data["max_connections"] do
      {:ok,
       %{
         host: ip,
         port: port,
         max_connections: connections,
         limits: %{max_concurrent: concurrent, max_queue: queue, queue_timeout_ms: timeout}
       }}
    else
      _ -> {:error, {:server, :invalid_listener}}
    end
  end

  defp listener(_), do: {:error, {:server, :missing_listener}}

  defp auth(data, dir) when is_map(data) do
    with :ok <- keys(data, ~w(issuer audience algorithm public_key)),
         issuer when is_binary(issuer) and issuer != "" <- data["issuer"],
         audience when is_binary(audience) and audience != "" <- data["audience"],
         algorithm when algorithm in ~w(RS256 ES256) <- data["algorithm"],
         key when is_binary(key) and key != "" <- data["public_key"],
         key_path = Path.expand(key, dir),
         true <- File.regular?(key_path) do
      {:ok, %{issuer: issuer, audience: audience, algorithm: algorithm, public_key: key_path}}
    else
      _ -> {:error, {:server, :invalid_auth}}
    end
  end

  defp auth(_, _), do: {:error, {:server, :missing_auth}}

  defp projects(data, dir) when is_map(data) and map_size(data) > 0 do
    Enum.reduce_while(data, {:ok, %{}}, fn {id, project}, {:ok, acc} ->
      with true <- is_binary(id) and id != "",
           true <- is_map(project),
           :ok <- keys(project, ~w(config)),
           path when is_binary(path) and path != "" <- project["config"],
           expanded = Path.expand(path, dir),
           true <- File.regular?(expanded) do
        {:cont, {:ok, Map.put(acc, id, expanded)}}
      else
        _ -> {:halt, {:error, {:server, :invalid_project, id}}}
      end
    end)
  end

  defp projects(_, _), do: {:error, {:server, :missing_projects}}

  defp keys(data, allowed) when is_map(data) do
    case Map.keys(data) -- allowed do
      [] -> :ok
      [key | _] -> {:error, {:server, :unknown_key, key}}
    end
  end

  defp keys(_, _), do: {:error, {:server, :invalid_table}}

  defp parse_ip(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, ip}
      _ -> {:error, :invalid_host}
    end
  end
end
