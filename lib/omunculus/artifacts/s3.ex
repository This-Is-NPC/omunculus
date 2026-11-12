defmodule Omunculus.Artifacts.S3 do
  @moduledoc """
  The `[settings.s3]` table and a small client for the bucket it names:
  any S3-compatible service (AWS S3, MinIO, Cloudflare R2, Backblaze B2).
  Requests are signed with SigV4 by `Req`. The table holds `bucket`,
  `endpoint`, `region`, `prefix`, `path_style` and `credentials`, which
  binds `access_key_id` and `secret_access_key` (and optionally
  `session_token`) to `[auth]` providers, so no secret is in the file.
  """

  alias Omunculus.Secrets

  @keys ~w(bucket endpoint region prefix path_style credentials)
  @bindings ~w(access_key_id secret_access_key session_token)

  @type settings :: %{
          bucket: String.t(),
          endpoint: URI.t(),
          region: String.t(),
          prefix: String.t(),
          path_style: boolean,
          credentials: %{String.t() => String.t()}
        }

  @doc "Parses the `[settings.s3]` table `data` against the project's `[auth]` providers."
  @spec parse(map, %{String.t() => map}) :: {:ok, settings} | {:error, term}
  def parse(data, _providers) when map_size(data) == 0, do: {:error, {:s3, :missing}}

  def parse(data, providers) do
    with [] <- Map.keys(data) -- @keys,
         {:ok, bucket} <- text(data, "bucket"),
         {:ok, endpoint} <- endpoint(data),
         {:ok, region} <- text(data, "region"),
         {:ok, prefix} <- prefix(data),
         {:ok, path_style} <- boolean(data),
         {:ok, credentials} <- credentials(data, providers) do
      {:ok,
       %{
         bucket: bucket,
         endpoint: endpoint,
         region: region,
         prefix: prefix,
         path_style: path_style,
         credentials: credentials
       }}
    else
      [key | _] -> {:error, {:s3, {:unknown_key, key}}}
      {:error, _reason} = error -> error
    end
  end

  defp text(data, key) do
    case data do
      %{^key => value} when is_binary(value) and value != "" -> {:ok, value}
      _invalid -> {:error, {:s3, {:invalid, key}}}
    end
  end

  defp endpoint(data) do
    with {:ok, url} <- text(data, "endpoint"),
         %URI{scheme: scheme, host: host, path: path} = uri
         when scheme in ["http", "https"] and is_binary(host) and path in [nil, "", "/"] <-
           URI.parse(url) do
      {:ok, uri}
    else
      _invalid -> {:error, {:s3, {:invalid, :endpoint}}}
    end
  end

  # A key prefix without edge slashes; empty for the bucket's root.
  defp prefix(%{"prefix" => prefix}) when is_binary(prefix), do: {:ok, String.trim(prefix, "/")}
  defp prefix(_data), do: {:error, {:s3, {:invalid, :prefix}}}

  defp boolean(%{"path_style" => value}) when is_boolean(value), do: {:ok, value}
  defp boolean(_data), do: {:error, {:s3, {:invalid, :path_style}}}

  defp credentials(%{"credentials" => binding}, providers) when is_map(binding) do
    cond do
      Map.keys(binding) -- @bindings != [] ->
        {:error, {:s3, {:invalid, :credentials}}}

      not Enum.all?(~w(access_key_id secret_access_key), &Map.has_key?(binding, &1)) ->
        {:error, {:s3, {:invalid, :credentials}}}

      provider = Enum.find(Map.values(binding), &(not Map.has_key?(providers, &1))) ->
        {:error, {:s3, {:unknown_provider, provider}}}

      true ->
        {:ok, binding}
    end
  end

  defp credentials(_data, _providers), do: {:error, {:s3, {:invalid, :credentials}}}

  @doc "The request options that sign calls to the bucket: the credentials resolved now."
  @spec signer(Omunculus.Config.t(), settings) :: {:ok, keyword} | {:error, term}
  def signer(config, settings) do
    with {:ok, values} <- Secrets.resolve(config, settings.credentials) do
      {:ok,
       [
         access_key_id: values["access_key_id"],
         secret_access_key: values["secret_access_key"],
         region: settings.region,
         service: "s3"
       ] ++ if(values["session_token"], do: [token: values["session_token"]], else: [])}
    end
  end

  @doc "The object key `suffix` under the project's prefix."
  @spec key(settings, String.t()) :: String.t()
  def key(%{prefix: ""}, suffix), do: suffix
  def key(%{prefix: prefix}, suffix), do: prefix <> "/" <> suffix

  @doc "Whether the object `key` exists."
  @spec exists?(settings, keyword, String.t()) :: {:ok, boolean} | {:error, term}
  def exists?(settings, signer, key) do
    case request(settings, signer, :head, key, []) do
      {:ok, %{status: 200}} -> {:ok, true}
      {:ok, %{status: 404}} -> {:ok, false}
      other -> failure(other)
    end
  end

  @doc "Writes `body` as the object `key`."
  @spec put(settings, keyword, String.t(), binary) :: :ok | {:error, term}
  def put(settings, signer, key, body) do
    case request(settings, signer, :put, key, body: body) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> failure(other)
    end
  end

  @doc "Reads the object `key`."
  @spec get(settings, keyword, String.t()) :: {:ok, binary} | {:error, term}
  def get(settings, signer, key) do
    case request(settings, signer, :get, key, decode_body: false) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      other -> failure(other)
    end
  end

  @doc "Every key that begins with `prefix`, across pages."
  @spec list(settings, keyword, String.t()) :: {:ok, [String.t()]} | {:error, term}
  def list(settings, signer, prefix), do: list(settings, signer, prefix, nil, [])

  defp list(settings, signer, prefix, token, keys) do
    params =
      [{"list-type", "2"}, {"prefix", prefix}] ++
        if(token, do: [{"continuation-token", token}], else: [])

    case request(settings, signer, :get, "",
           query: URI.encode_query(params, :rfc3986),
           decode_body: false
         ) do
      {:ok, %{status: 200, body: xml}} ->
        keys = keys ++ tags(xml, "Key")

        case tags(xml, "NextContinuationToken") do
          [token] -> list(settings, signer, prefix, token, keys)
          [] -> {:ok, keys}
        end

      other ->
        failure(other)
    end
  end

  defp tags(xml, tag) do
    ~r/<#{tag}>(.*?)<\/#{tag}>/s
    |> Regex.scan(xml, capture: :all_but_first)
    |> Enum.map(fn [text] -> unescape(text) end)
  end

  defp unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end

  # The query is encoded here, with `%20` for a space, as SigV4 signs it.
  defp request(settings, signer, method, key, options) do
    {query, options} = Keyword.pop(options, :query)
    url = url(settings, key) <> if(query, do: "?" <> query, else: "")

    Req.request(
      [method: method, url: url, aws_sigv4: signer, retry: false, receive_timeout: 30_000] ++
        options
    )
  end

  defp url(%{path_style: true} = settings, key) do
    base = %{settings.endpoint | path: "/" <> settings.bucket}
    URI.to_string(base) <> path(key)
  end

  defp url(settings, key) do
    base = %{settings.endpoint | host: settings.bucket <> "." <> settings.endpoint.host, path: ""}
    URI.to_string(base) <> if(key == "", do: "/", else: path(key))
  end

  defp path(""), do: "/"

  defp path(key),
    do:
      "/" <>
        Enum.map_join(
          String.split(key, "/"),
          "/",
          &URI.encode(&1, fn c -> URI.char_unreserved?(c) end)
        )

  defp failure({:ok, %{status: status}}), do: {:error, {:s3, {:status, status}}}
  defp failure({:error, reason}), do: {:error, {:s3, {:request, reason}}}
end
