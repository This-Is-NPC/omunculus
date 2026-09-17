defmodule Omunculus.Tools.Prompt do
  @moduledoc """
  Builtin `prompt` tool: prints the assembled prompt of a run. `--run`
  selects the run; without it the last run by `started_at` is used.
  """

  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(%{view: %{"prompt" => %{body: body}}}) when is_binary(body) do
    Out.ok(body)
  end

  def run(_input), do: Out.fail("no assembled prompt")
end
