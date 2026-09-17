defmodule Omunculus.Config.Layer do
  @moduledoc """
  One ceiling layer of spec §5: the mode for what the lists do not cite,
  the four class lists, and `pinned` (names or groups that become cards
  in the assembled prompt when `tool_search` is effective).
  """
  defstruct mode: nil, granted: [], negotiable: [], human: [], deny: [], pinned: []

  @type t :: %__MODULE__{
          mode: nil | String.t(),
          granted: [String.t()],
          negotiable: [String.t()],
          human: [String.t()],
          deny: [String.t()],
          pinned: [String.t()]
        }
end
