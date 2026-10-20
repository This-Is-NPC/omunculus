defmodule Omunculus.Tools.RequestAccess do
  @moduledoc """
  Builtin `request_access` tool: emits one `request` for
  everything in `access`, each a `{kind, name}`: a tool, a path, a
  directory, or a sandbox capability (`resource`) named in `[execution]
  resources`. Each option grants all of them: one `grant_<scope>` per
  scope of the `grant_scopes` view, permanent; `deny`, with no call; and,
  in a run with a work, `grant`, which grants on that work. In a run with
  a work, a `comment` with the `report` on that work comes first. Its
  manifest's `then` appends `end`. Optional `to` names a logical route.
  """

  alias Omunculus.Config
  alias Omunculus.Tools.{Args, Out}

  @required ~w(report reason)
  @kinds ~w(tool resource path directory)

  @spec run(map) :: map
  def run(%{args: args} = input) do
    with nil <- Args.missing(args, @required),
         {:ok, access} <- access(args["access"]) do
      emit(input, access)
    else
      {:error, message} -> Out.fail(message)
      message -> Out.fail(message)
    end
  end

  defp access([_ | _] = access) do
    Enum.reduce_while(access, {:ok, []}, fn item, {:ok, acc} ->
      case item(item) do
        {:ok, grant} -> {:cont, {:ok, acc ++ [grant]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp access(_access), do: {:error, "access required: a list of {kind, name}"}

  defp item(%{"kind" => "resource", "name" => name}) when is_binary(name) do
    if name in Config.known_resources(),
      do: {:ok, %{"kind" => "resource", "name" => name}},
      else: {:error, "unsupported resource: #{name}"}
  end

  defp item(%{"kind" => kind, "name" => name})
       when kind in @kinds and is_binary(name) and name != "",
       do: {:ok, %{"kind" => kind, "name" => name}}

  defp item(%{"kind" => kind}) when is_binary(kind) and kind not in @kinds,
    do: {:error, "unsupported access kind: #{kind}"}

  defp item(_item), do: {:error, "each access needs a kind and a name"}

  defp emit(%{args: %{"report" => report, "reason" => reason}} = input, access) do
    work_id = input.work_id

    comment =
      if work_id,
        do: [%{"type" => "comment", "body" => %{"work_id" => work_id, "body" => report}}],
        else: []

    options = options(input.view["grant_scopes"], access, work_id)
    request = %{"reason" => reason, "options" => options} |> Args.put_present("to", input.args)
    Out.ok("", comment ++ [%{"type" => "request", "body" => request}])
  end

  defp options(scopes, access, work_id) do
    permanent =
      scopes
      |> Map.new(&{"grant_#{&1}", grant_calls(access, %{"scope" => &1})})
      |> Map.put("deny", [])

    if work_id, do: Map.put(permanent, "grant", grant_calls(access, %{})), else: permanent
  end

  defp grant_calls(access, extra),
    do: Enum.map(access, &%{"name" => "grant", "args" => Map.merge(&1, extra)})
end
