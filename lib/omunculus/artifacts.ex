defmodule Omunculus.Artifacts do
  @moduledoc """
  The documents agents make and hand on: typed, versioned, immutable
  records of a conversation (`docs/design.md §10`). A version is described
  by `%{"name", "kind", "version", "media_type", "bytes", "sha256"}` and an
  optional `"note"`, which the `artifact` event that carries it holds. Its
  content is kept by `Omunculus.Attachments`, the one backend: a backend
  is what `put/5` and `read/2` use to keep content and give it back.
  """

  alias Omunculus.Attachments

  @type version :: %{String.t() => term}

  @doc "Keeps `content` for a version of `name`, as the backend describes it."
  @spec put(Attachments.store(), String.t(), term, String.t(), binary) ::
          {:ok, Attachments.meta()} | {:error, {:artifact | :attachment, term}}
  def put(store, name, kind, media_type, content) do
    if is_binary(kind) and Regex.match?(~r/\A[a-z][a-z0-9_-]*\z/, kind),
      do: Attachments.put(store, name, media_type, content),
      else: {:error, {:artifact, {:invalid, :kind}}}
  end

  @doc "The content of `version`, as the backend keeps it."
  @spec read(Attachments.store(), version) :: {:ok, binary} | {:error, {:attachment, term}}
  def read(store, %{"sha256" => sha256}) do
    with {:ok, path} <- Attachments.path(store, sha256) do
      case File.read(path) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, {:attachment, reason}}
      end
    end
  end

  @doc "The kind `name` already has among `versions`, or nil."
  @spec kind(String.t(), [version]) :: String.t() | nil
  def kind(name, versions) do
    case Enum.find(versions, &(&1["name"] == name)) do
      nil -> nil
      version -> version["kind"]
    end
  end

  @doc "The number the next version of `name` takes."
  @spec next(String.t(), [version]) :: pos_integer
  def next(name, versions), do: 1 + Enum.count(versions, &(&1["name"] == name))

  @doc "The version of `name` numbered `number`, the latest when it is nil."
  @spec find([version], String.t(), integer | nil) :: version | nil
  def find(versions, name, number) do
    named = Enum.filter(versions, &(&1["name"] == name))
    if number, do: Enum.find(named, &(&1["version"] == number)), else: List.last(named)
  end

  @doc "The versions grouped by artifact, in the order the artifacts first appear."
  @spec group([version]) :: [%{String.t() => term}]
  def group(versions) do
    versions
    |> Enum.uniq_by(& &1["name"])
    |> Enum.map(fn %{"name" => name, "kind" => kind} ->
      %{
        "name" => name,
        "kind" => kind,
        "versions" => Enum.filter(versions, &(&1["name"] == name))
      }
    end)
  end
end
