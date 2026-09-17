defmodule Omunculus.Auth do
  @moduledoc """
  Resolves a model's provider credential from `[auth]` and the JSON store
  at `[auth] store` (mode 0600). `api_key` reads the TOML `key` (`$VAR`,
  `!cmd`, or literal); an empty key falls back to a stored login.
  `oauth-code` and `tool` read the store and refresh under a file lock.
  """

  alias Omunculus.Config
  alias Omunculus.Tool.{Catalog, Invoke}

  @type credential :: %{access: String.t(), expires_at: String.t() | nil}

  @spec credential(Config.t(), String.t()) ::
          {:ok, credential() | nil} | {:error, term}
  def credential(%Config{} = config, provider_id) when is_binary(provider_id) do
    case Map.fetch(config.auth.providers, provider_id) do
      :error ->
        {:error, {:auth, :unknown_provider, provider_id}}

      {:ok, provider} ->
        resolve_credential(config, provider_id, provider)
    end
  end

  @spec put(Config.t(), String.t(), map) :: :ok | {:error, term}
  def put(%Config{auth: %{store: store}}, provider_id, record)
      when is_binary(store) and is_map(record) do
    with_store_lock(store, fn -> write_record(store, provider_id, record) end)
  end

  def put(%Config{}, _provider_id, _record), do: {:error, {:auth, :missing_store}}

  @spec delete(Config.t(), String.t()) :: :ok | {:error, term}
  def delete(%Config{auth: %{store: store}}, provider_id) when is_binary(store) do
    with_store_lock(store, fn ->
      contents = read_store_file(store)
      write_store_file(store, Map.delete(contents, provider_id))
      :ok
    end)
  end

  def delete(%Config{}, _provider_id), do: {:error, {:auth, :missing_store}}

  defp resolve_credential(config, provider_id, %{kind: "api_key", key: key}) do
    case resolve_key(key) do
      {:ok, ""} -> stored_api_key(config, provider_id)
      {:ok, access} -> {:ok, %{access: access, expires_at: nil}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_credential(config, provider_id, %{kind: kind} = provider)
       when kind in ["oauth-code", "tool"] do
    case config.auth.store do
      store when is_binary(store) ->
        with_store_lock(store, fn ->
          with {:ok, record} <- load_store_record(config, provider_id),
               {:ok, record} <- ensure_fresh(config, store, provider_id, provider, record) do
            {:ok, to_credential(record)}
          end
        end)

      _missing ->
        {:error, {:auth, :not_logged_in, provider_id}}
    end
  end

  defp resolve_credential(_config, provider_id, %{kind: kind}) do
    {:error, {:auth, provider_id, {:unknown_kind, kind}}}
  end

  defp load_store_record(%Config{auth: %{store: store}}, provider_id) when is_binary(store) do
    contents = read_store_file(store)

    case Map.fetch(contents, provider_id) do
      :error -> {:error, {:auth, :not_logged_in, provider_id}}
      {:ok, record} when is_map(record) -> {:ok, record}
      _ -> {:error, {:auth, :not_logged_in, provider_id}}
    end
  end

  defp load_store_record(%Config{}, provider_id),
    do: {:error, {:auth, :not_logged_in, provider_id}}

  defp stored_api_key(config, provider_id) do
    case load_store_record(config, provider_id) do
      {:ok, %{"type" => "api_key", "key" => key}} when is_binary(key) and key != "" ->
        {:ok, %{access: key, expires_at: nil}}

      {:ok, _record} ->
        {:ok, nil}

      {:error, {:auth, :not_logged_in, _}} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp to_credential(record) do
    %{
      access: Map.get(record, "access", ""),
      expires_at: Map.get(record, "expires_at")
    }
  end

  defp ensure_fresh(_config, store, provider_id, %{kind: "oauth-code"} = provider, record) do
    if expired?(record),
      do: refresh_oauth(store, provider_id, provider, record),
      else: {:ok, record}
  end

  defp ensure_fresh(config, store, provider_id, %{kind: "tool"} = provider, record) do
    if expired?(record),
      do: refresh_tool(config, store, provider_id, provider, record),
      else: {:ok, record}
  end

  defp expired?(%{"expires_at" => "never"}), do: false

  defp expired?(%{"expires_at" => expires_at}) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, dt, _} -> DateTime.compare(dt, DateTime.utc_now(:second)) == :lt
      _ -> true
    end
  end

  defp expired?(_record), do: true

  defp refresh_oauth(store, provider_id, provider, record) do
    refresh_token = Map.get(record, "refresh")

    if is_binary(refresh_token) and refresh_token != "" do
      token_url = refresh_token_url(provider)
      client_id = provider.client_id

      case Req.post(token_url,
             form: [
               grant_type: "refresh_token",
               refresh_token: refresh_token,
               client_id: client_id
             ],
             receive_timeout: 30_000
           ) do
        {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
          with {:ok, updated} <- map_token_response(body, provider, record),
               :ok <- write_record(store, provider_id, updated) do
            {:ok, updated}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, {:auth, :refresh_failed, provider_id, status, body}}

        {:error, reason} ->
          {:error, {:auth, :refresh_failed, provider_id, reason}}
      end
    else
      {:error, {:auth, :not_logged_in, provider_id}}
    end
  end

  defp refresh_token_url(%{refresh: %{token_url: url}}) when is_binary(url), do: url
  defp refresh_token_url(%{token_url: url}), do: url

  defp refresh_tool(config, store, provider_id, %{refresh: refresh_name} = provider, record) do
    catalog = Catalog.discover(config.tools, config.mcp, nil)

    case Map.fetch(catalog, refresh_name) do
      :error ->
        {:error, {:auth, :missing_refresh_tool, refresh_name}}

      {:ok, manifest} ->
        input = %{
          name: refresh_name,
          args: %{},
          view: %{"credential" => record},
          run_id: nil,
          work_id: nil,
          workspace: nil,
          roots: [config.root],
          config_path: config.path
        }

        with {:ok, out} <- Invoke.call(manifest, input),
             true <- out.ok,
             {:ok, parsed} <- Jason.decode(out.output),
             {:ok, updated} <- map_token_response(parsed, provider, record),
             :ok <- write_record(store, provider_id, updated) do
          {:ok, updated}
        else
          false ->
            {:error, {:auth, :refresh_failed, provider_id, :tool_failed}}

          {:error, %Jason.DecodeError{}} ->
            {:error, {:auth, :refresh_failed, provider_id, :invalid_json}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc false
  @spec map_token_response(map, map, map) :: {:ok, map} | {:error, term}
  def map_token_response(body, provider, record) do
    access_field = provider.credential.access
    expires_field = provider.credential.expires
    refresh_field = Map.get(provider.credential, :refresh)

    access = Map.get(body, access_field)

    if is_binary(access) and access != "" do
      expires_at = expires_at_from(body, expires_field)

      updated =
        record
        |> Map.put("type", "oauth")
        |> Map.put("access", access)
        |> Map.put("expires_at", expires_at)
        |> maybe_put_refresh(body, refresh_field)

      {:ok, updated}
    else
      {:error, {:auth, :invalid_token_response, body}}
    end
  end

  defp maybe_put_refresh(record, _body, nil), do: record

  defp maybe_put_refresh(record, body, refresh_field) do
    case Map.get(body, refresh_field) do
      token when is_binary(token) and token != "" -> Map.put(record, "refresh", token)
      _ -> record
    end
  end

  defp expires_at_from(body, expires_field) do
    case Map.get(body, expires_field) do
      "never" ->
        "never"

      value when is_integer(value) ->
        DateTime.utc_now(:second)
        |> DateTime.add(value, :second)
        |> DateTime.to_iso8601()

      value when is_binary(value) ->
        value

      _ ->
        nil
    end
  end

  @doc false
  @spec resolve_key(String.t()) :: {:ok, String.t()} | {:error, term}
  def resolve_key(""), do: {:ok, ""}

  def resolve_key("$" <> var) do
    case System.get_env(var) do
      nil -> {:error, {:auth, :missing_env, var}}
      value -> {:ok, value}
    end
  end

  def resolve_key("!" <> cmd) do
    cache_key = {:auth_cmd, cmd}

    case Process.get(cache_key) do
      nil ->
        {output, status} = System.cmd("sh", ["-c", cmd], stderr_to_stdout: true)

        if status == 0 do
          value = String.trim(output)
          Process.put(cache_key, value)
          {:ok, value}
        else
          {:error, {:auth, :command_failed, cmd, status, String.trim(output)}}
        end

      value ->
        {:ok, value}
    end
  end

  def resolve_key(key), do: {:ok, key}

  defp read_store_file(path) do
    if File.regular?(path) do
      case File.read(path) do
        {:ok, ""} -> %{}
        {:ok, contents} -> Jason.decode!(contents)
        {:error, _} -> %{}
      end
    else
      %{}
    end
  end

  defp write_store_file(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(contents))
    File.chmod!(path, 0o600)
  end

  defp write_record(store, provider_id, record) do
    contents = read_store_file(store)
    write_store_file(store, Map.put(contents, provider_id, record))
    :ok
  end

  defp with_store_lock(store_path, fun) do
    lock_path = store_path <> ".lock"
    File.mkdir_p!(Path.dirname(lock_path))

    case acquire_lock_fd(lock_path) do
      {:ok, fd} ->
        try do
          fun.()
        after
          :file.close(fd)
          File.rm(lock_path)
        end

      {:error, reason} ->
        {:error, {:auth, :lock_failed, reason}}
    end
  end

  defp acquire_lock_fd(path, attempts \\ 100) do
    case :file.open(String.to_charlist(path), [:write, :raw, :exclusive]) do
      {:ok, fd} ->
        {:ok, fd}

      {:error, :eexist} when attempts > 0 ->
        Process.sleep(20)
        acquire_lock_fd(path, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
