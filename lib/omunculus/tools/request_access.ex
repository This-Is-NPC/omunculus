defmodule Omunculus.Tools.RequestAccess do
  @moduledoc """
  Builtin `request_access` tool, per spec §3.5: emits a `request` for a
  tool, path, or directory. Sandbox capabilities go through `request_sandbox`.
  The options are `grant`, one `grant_<scope>` per scope of the
  `grant_scopes` view, each a `grant` call, and `deny`, with no call. In a run with a work, a
  `comment` with the `report` on that work comes first. Its manifest's
  `then` appends `end`.
  """

  alias Omunculus.Tools.{Args, Out}

  @required ~w(report kind name reason)
  @kinds ~w(tool path directory)

  @spec run(map) :: map
  def run(%{args: args} = input) do
    case Args.missing(args, @required) do
      nil -> validate(input)
      message -> Out.fail(message)
    end
  end

  defp validate(%{args: %{"kind" => kind, "name" => name}} = input) when kind in @kinds,
    do: emit(input, kind, name)

  defp validate(%{args: %{"kind" => kind}}), do: Out.fail("unsupported access kind: #{kind}")

  @doc """
  The emits of a request tool: the `report` as a comment on the run's
  work, when it has one, then the `request` for `name` of `kind`.
  """
  @spec emit(map, String.t(), String.t()) :: map
  def emit(%{args: %{"report" => report, "reason" => reason}} = input, kind, name) do
    work_id = input.work_id

    comment =
      if work_id,
        do: [%{"type" => "comment", "body" => %{"work_id" => work_id, "body" => report}}],
        else: []

    request = %{"reason" => reason, "options" => options(input.view["grant_scopes"], kind, name)}
    Out.ok("", comment ++ [%{"type" => "request", "body" => request}])
  end

  defp options(scopes, kind, name) do
    grant = %{"name" => name, "kind" => kind}

    scopes
    |> Map.new(&{"grant_#{&1}", [grant_call(Map.put(grant, "scope", &1))]})
    |> Map.put("grant", [grant_call(grant)])
    |> Map.put("deny", [])
  end

  defp grant_call(args), do: %{"name" => "grant", "args" => args}
end
