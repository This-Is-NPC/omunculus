defmodule Omunculus.Artifacts.Sync do
  @moduledoc """
  Copies the artifact versions of a conversation to the `[settings.s3]` bucket and
  back. The bucket holds each version's content once, under its SHA-256
  (`objects/<sha256>`), and one JSON record per version
  (`conversations/<conversation>/<name>/<version>.json`) that describes
  it as its `artifact` event does. Objects and records never change, so
  both directions skip what is already there and are safe to rerun.
  """

  alias Omunculus.Artifacts
  alias Omunculus.Artifacts.S3

  @record_keys ~w(name kind version media_type bytes sha256 note by at event_id tool)

  @doc "Uploads the content and record of each of `versions` the bucket lacks."
  @spec push(Omunculus.Config.t(), S3.settings(), String.t(), [Artifacts.version()]) ::
          {:ok, %{pushed: non_neg_integer, present: non_neg_integer}} | {:error, term}
  def push(config, settings, conversation_id, versions) do
    with {:ok, signer} <- S3.signer(config, settings) do
      Enum.reduce_while(versions, {:ok, %{pushed: 0, present: 0}}, fn version, {:ok, count} ->
        with {:ok, object} <-
               ensure(settings, signer, object_key(settings, version), fn ->
                 read(config, version)
               end),
             {:ok, record} <-
               ensure(settings, signer, record_key(settings, conversation_id, version), fn ->
                 {:ok, version |> Map.take(@record_keys) |> Jason.encode!()}
               end) do
          {:cont, {:ok, tally(count, object, record)}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp read(config, version), do: Artifacts.read(config.store, version)

  # Writes the object unless it exists.
  defp ensure(settings, signer, key, content) do
    with {:ok, false} <- S3.exists?(settings, signer, key),
         {:ok, body} <- content.(),
         :ok <- S3.put(settings, signer, key, body) do
      {:ok, :pushed}
    else
      {:ok, true} -> {:ok, :present}
      {:error, _reason} = error -> error
    end
  end

  defp tally(%{pushed: pushed, present: present}, object, record) do
    results = [object, record]

    %{
      pushed: pushed + Enum.count(results, &(&1 == :pushed)),
      present: present + Enum.count(results, &(&1 == :present))
    }
  end

  @doc """
  The `artifact` actions that bring `conversation_id`'s versions in the
  bucket into a conversation that holds `held`: for each name, the
  versions after the ones it has, in order. Content that is text or bytes
  comes back as the same bytes; a gap in the numbers is left out and named
  in `skipped`.
  """
  @spec pull(Omunculus.Config.t(), S3.settings(), String.t(), [Artifacts.version()]) ::
          {:ok, %{emit: [map], skipped: [String.t()]}} | {:error, term}
  def pull(config, settings, conversation_id, held) do
    with {:ok, signer} <- S3.signer(config, settings),
         {:ok, keys} <-
           S3.list(settings, signer, S3.key(settings, "conversations/#{conversation_id}/")),
         {:ok, records} <- records(settings, signer, keys) do
      records
      |> Enum.group_by(& &1["name"])
      |> Enum.sort()
      |> Enum.reduce_while({:ok, %{emit: [], skipped: []}}, fn {name, versions}, {:ok, acc} ->
        have = Enum.count(held, &(&1["name"] == name))

        case restore(settings, signer, name, have, Enum.sort_by(versions, & &1["version"])) do
          {:ok, emit, skipped} ->
            {:cont, {:ok, %{emit: acc.emit ++ emit, skipped: acc.skipped ++ skipped}}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
    end
  end

  defp records(settings, signer, keys) do
    keys
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, acc} ->
      with {:ok, body} <- S3.get(settings, signer, key),
           {:ok,
            %{"name" => _, "kind" => _, "version" => _, "sha256" => _, "media_type" => _} = record} <-
             Jason.decode(body) do
        {:cont, {:ok, [record | acc]}}
      else
        {:error, {:s3, _reason}} = error -> {:halt, error}
        _invalid -> {:halt, {:error, {:s3, {:record, key}}}}
      end
    end)
  end

  # The versions numbered after `have`, while they follow one another.
  defp restore(settings, signer, name, have, versions) do
    versions
    |> Enum.filter(&(&1["version"] > have))
    |> Enum.reduce_while({:ok, [], [], have}, fn version, {:ok, emit, skipped, last} ->
      with true <- version["version"] == last + 1,
           {:ok, content} <- S3.get(settings, signer, object_key(settings, version)),
           true <-
             sha256(content) == version["sha256"] or {:error, {:s3, {:digest, version["sha256"]}}} do
        {:cont, {:ok, emit ++ [action(version, content, last)], skipped, last + 1}}
      else
        {:error, _reason} = error -> {:halt, error}
        _unrestorable -> {:halt, {:ok, emit, skipped ++ ["#{name} v#{version["version"]}"], last}}
      end
    end)
    |> case do
      {:ok, emit, skipped, _last} -> {:ok, emit, skipped}
      {:error, _reason} = error -> error
    end
  end

  defp action(version, content, base) do
    body =
      %{
        "name" => version["name"],
        "kind" => version["kind"],
        "media_type" => version["media_type"],
        "base" => base
      }
      |> Map.merge(Artifacts.payload(content))
      |> then(&if(is_binary(version["note"]), do: Map.put(&1, "note", version["note"]), else: &1))

    %{"type" => "artifact", "body" => body}
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp object_key(settings, %{"sha256" => sha256}), do: S3.key(settings, "objects/#{sha256}")

  defp record_key(settings, conversation_id, version),
    do:
      S3.key(
        settings,
        "conversations/#{conversation_id}/#{version["name"]}/#{version["version"]}.json"
      )
end
