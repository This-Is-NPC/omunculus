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
  @spec put(Attachments.store(), String.t(), term, term, binary) ::
          {:ok, Attachments.meta()} | {:error, {:artifact | :attachment, term}}
  def put(store, name, kind, media_type, content) do
    with :ok <- valid_kind(kind), do: Attachments.put(store, name, media_type, content)
  end

  @doc """
  Whether the next version of `name` may be written among `versions`: a
  kind that is a lowercase word and the name's own, a name, media type and
  size the backend accepts, and, when `base` is given, that it is still
  the number of the name's latest version (0 for none).
  """
  @spec check(Attachments.store(), [version], term, term, term, non_neg_integer, term) ::
          :ok | {:error, {:artifact | :attachment, term}}
  def check(store, versions, name, kind, media_type, size, base) do
    current = Enum.count(versions, &(&1["name"] == name))

    with :ok <- valid_kind(kind),
         :ok <- Attachments.validate(store, name, media_type, size),
         :ok <- same_kind(name, kind, versions) do
      if is_nil(base) or base == current,
        do: :ok,
        else: {:error, {:artifact, {:conflict, name, base, current}}}
    end
  end

  defp valid_kind(kind) do
    if is_binary(kind) and Regex.match?(~r/\A[a-z][a-z0-9_-]*\z/, kind),
      do: :ok,
      else: {:error, {:artifact, {:invalid, :kind}}}
  end

  defp same_kind(name, kind, versions) do
    case kind(name, versions) do
      nil -> :ok
      ^kind -> :ok
      other -> {:error, {:artifact, {:kind, name, other}}}
    end
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

  @doc """
  The latest version of `name` when it already holds `content` of
  `media_type` (the same SHA-256 and media type), else nil. Such a write
  makes no new version. The kind is the name's own, which `check/7` keeps.
  """
  @spec unchanged([version], String.t(), term, binary) :: version | nil
  def unchanged(versions, name, media_type, content) do
    sha256 = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    case find(versions, name, nil) do
      %{"sha256" => ^sha256, "media_type" => ^media_type} = latest -> latest
      _other -> nil
    end
  end

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
