defmodule Omunculus.Tools.Login do
  @moduledoc """
  Builtin `login` CLI tool: writes a provider's credential to `[auth] store`.
  """

  alias Omunculus.{Auth, Config, Harness, Project}
  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, config_path: config_path}) when is_binary(config_path) do
    case Args.missing(args, ~w(provider)) do
      nil ->
        with {:ok, config} <- Config.load(config_path),
             {:ok, project} <- Project.open(config) do
          try do
            login(config, project, args)
          after
            Project.close(project)
          end
        else
          {:error, reason} -> Out.fail(inspect(reason))
        end

      message ->
        Out.fail(message)
    end
  end

  def run(_input), do: Out.fail("config_path required")

  defp login(config, project, args) do
    provider_id = args["provider"]

    case Map.fetch(config.auth.providers, provider_id) do
      :error ->
        Out.fail(Out.unknown_auth_provider(provider_id))

      {:ok, %{kind: "api_key"}} ->
        api_key_login(config, provider_id, args)

      {:ok, %{kind: "oauth-code"} = provider} ->
        oauth_login(config, provider_id, provider, args)

      {:ok, %{kind: "tool", login: login_name}} ->
        tool_login(config, project, provider_id, login_name)

      {:ok, %{kind: kind}} ->
        Out.fail(Out.unknown_auth_kind(kind))
    end
  end

  defp api_key_login(config, provider_id, args) do
    key =
      case Args.present(args, "key") do
        nil -> String.trim(IO.gets(Out.api_key_prompt()) || "")
        value -> value
      end

    with :ok <- Auth.put(config, provider_id, %{"type" => "api_key", "key" => key}) do
      Out.ok(Out.logged_in(provider_id))
    else
      {:error, reason} -> Out.fail(inspect(reason))
    end
  end

  defp oauth_login(config, provider_id, provider, args) do
    pkce = if provider.pkce, do: pkce_pair(), else: nil

    with :ok <- ensure_store(config),
         {:ok, code, redirect_uri} <- fetch_oauth_code(provider, args, pkce),
         {:ok, body} <- exchange_code(provider, code, redirect_uri, pkce),
         {:ok, record} <- Auth.map_token_response(body, provider, %{"type" => "oauth"}),
         :ok <- Auth.put(config, provider_id, record) do
      Out.ok(Out.logged_in(provider_id))
    else
      {:error, reason} -> Out.fail(inspect(reason))
    end
  end

  defp tool_login(config, project, provider_id, login_name) do
    ctx = %{trigger: "cli", run_id: nil, author: "human", agent: nil}

    with :ok <- ensure_store(config),
         {:ok, out, _events} <- Harness.dispatch(project, login_name, %{}, ctx),
         true <- out.ok,
         {:ok, parsed} <- Jason.decode(out.output),
         {:ok, record} <- tool_record(parsed),
         :ok <- Auth.put(config, provider_id, record) do
      Out.ok(Out.logged_in(provider_id))
    else
      false -> Out.fail(Out.login_tool_failed())
      {:error, reason} -> Out.fail(inspect(reason))
    end
  end

  defp tool_record(parsed) when is_map(parsed) do
    access = Map.get(parsed, "access")

    if is_binary(access) and access != "" do
      record =
        %{"type" => "oauth", "access" => access}
        |> maybe_put(parsed, "refresh")
        |> maybe_put(parsed, "expires_at")

      {:ok, record}
    else
      {:error, {:auth, :invalid_login_output, parsed}}
    end
  end

  defp tool_record(_parsed), do: {:error, {:auth, :invalid_login_output, %{}}}

  defp maybe_put(record, source, key) do
    case Map.get(source, key) do
      value when is_binary(value) -> Map.put(record, key, value)
      _ -> record
    end
  end

  defp ensure_store(%{auth: %{store: store}}) when is_binary(store), do: :ok
  defp ensure_store(_config), do: {:error, {:auth, :missing_store}}

  defp fetch_oauth_code(provider, args, pkce) do
    case Args.present(args, "redirect_url") do
      nil -> callback_code(provider, pkce)
      url -> redirect_code(provider, url)
    end
  end

  defp redirect_code(provider, url) do
    with %URI{query: query} <- URI.parse(url),
         %{"code" => code} <- URI.decode_query(query || "") do
      {:ok, code, redirect_uri(provider)}
    else
      _ -> {:error, {:auth, :invalid_redirect_url, url}}
    end
  end

  defp callback_code(provider, pkce) do
    challenge = pkce && elem(pkce, 1)
    open_browser(build_authorize_url(provider, challenge))

    case await_callback(provider.callback) do
      {:ok, code} -> {:ok, code, redirect_uri(provider)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pkce_pair do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp build_authorize_url(provider, code_challenge) do
    query =
      %{
        "response_type" => "code",
        "client_id" => provider.client_id,
        "redirect_uri" => redirect_uri(provider),
        "scope" => Enum.join(provider.scopes, " ")
      }
      |> Map.merge(provider.authorize_params || %{})
      |> maybe_put_pkce(code_challenge)
      |> URI.encode_query()

    provider.authorize_url <> "?" <> query
  end

  defp maybe_put_pkce(query, nil), do: query

  defp maybe_put_pkce(query, challenge) do
    query
    |> Map.put("code_challenge", challenge)
    |> Map.put("code_challenge_method", "S256")
  end

  defp redirect_uri(%{callback: %{host: host, port: port, path: path}}) do
    "http://#{host}:#{port}#{path}"
  end

  defp exchange_code(provider, code, redirect_uri, pkce) do
    form =
      [
        grant_type: "authorization_code",
        code: code,
        client_id: provider.client_id,
        redirect_uri: redirect_uri
      ]
      |> maybe_put_verifier(pkce)

    case Req.post(provider.token_url, form: form, receive_timeout: 30_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:auth, :token_exchange_failed, status, body}}

      {:error, reason} ->
        {:error, {:auth, :token_exchange_failed, reason}}
    end
  end

  defp maybe_put_verifier(form, nil), do: form

  defp maybe_put_verifier(form, {verifier, _challenge}),
    do: Keyword.put(form, :code_verifier, verifier)

  defp open_browser(url) do
    cond do
      exe = System.find_executable("xdg-open") ->
        System.cmd(exe, [url], stderr_to_stdout: true)

      exe = System.find_executable("open") ->
        System.cmd(exe, [url], stderr_to_stdout: true)

      true ->
        :ok
    end
  end

  defp await_callback(%{host: host, port: port, path: path}) do
    ip = host_to_ip(host)

    with {:ok, listen} <-
           :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, ip: ip]),
         {:ok, code} <- accept_request(listen, path, 120_000) do
      :gen_tcp.close(listen)
      {:ok, code}
    else
      {:error, reason} -> {:error, {:auth, :callback_failed, reason}}
    end
  catch
    :exit, reason -> {:error, {:auth, :callback_failed, reason}}
  end

  defp accept_request(listen, expected_path, timeout_ms) do
    task =
      Task.async(fn ->
        case :gen_tcp.accept(listen, timeout_ms) do
          {:ok, socket} ->
            result = read_request(socket, expected_path)
            respond(socket, if(match?({:ok, _}, result), do: 200, else: 400), "done")
            :gen_tcp.close(socket)
            result

          {:error, reason} ->
            {:error, reason}
        end
      end)

    case Task.await(task, timeout_ms + 1_000) do
      {:ok, code} -> {:ok, code}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_request(socket, expected_path) do
    case :gen_tcp.recv(socket, 0, 120_000) do
      {:ok, packet} -> parse_request(to_string(packet), expected_path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_request(packet, expected_path) do
    [request_line | _] = String.split(packet, "\r\n", parts: 2)
    [method, raw_path | _] = String.split(request_line, " ", parts: 3)

    if method == "GET" do
      path = raw_path |> String.split("?", parts: 2) |> hd()

      if path == expected_path do
        query =
          case String.split(raw_path, "?", parts: 2) do
            [_path, query] -> URI.decode_query(query)
            [_path] -> %{}
          end

        case Map.get(query, "code") do
          code when is_binary(code) and code != "" -> {:ok, code}
          _ -> {:error, :missing_code}
        end
      else
        {:error, {:bad_path, path}}
      end
    else
      {:error, {:bad_method, method}}
    end
  end

  defp respond(socket, status, body) do
    response =
      "HTTP/1.1 #{status} OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"

    :gen_tcp.send(socket, response)
  end

  defp host_to_ip("localhost"), do: {127, 0, 0, 1}
  defp host_to_ip("127.0.0.1"), do: {127, 0, 0, 1}

  defp host_to_ip(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> ip
      {:error, _} -> {127, 0, 0, 1}
    end
  end
end
