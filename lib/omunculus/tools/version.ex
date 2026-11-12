defmodule Omunculus.Tools.Version do
  @moduledoc "`version` tool: the version of the running application."

  alias Omunculus.Tools.Out

  @spec current() :: String.t()
  def current, do: :omunculus |> Application.spec(:vsn) |> to_string()

  @spec run(map) :: map
  def run(_input), do: Out.ok(current())
end
