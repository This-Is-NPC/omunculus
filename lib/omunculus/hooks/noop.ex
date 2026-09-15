defmodule Omunculus.Hooks.Noop do
  @moduledoc """
  Default hook, per spec §9.6: reacts to nothing. Used by `on-request`,
  `on-notify`, `on-continue` and `on-break` until a project overrides them.
  """

  @spec run(map) :: map
  def run(_input), do: %{"ok" => true, "output" => "", "emit" => []}
end
