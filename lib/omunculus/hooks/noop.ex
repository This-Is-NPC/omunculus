defmodule Omunculus.Hooks.Noop do
  @moduledoc """
  Default hook: reacts to nothing. Used by `on-request`,
  `on-notify`, `on-continue` and `on-break` until a project overrides them.
  """

  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(_input), do: Out.ok()
end
