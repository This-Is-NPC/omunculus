defmodule Omunculus.Config.Layer do
  @moduledoc """
  One ceiling layer of spec §5: the mode for what the lists do not cite,
  and the four lists.
  """
  defstruct mode: nil, granted: [], negotiable: [], human: [], deny: []

  @type t :: %__MODULE__{
          mode: nil | String.t(),
          granted: [String.t()],
          negotiable: [String.t()],
          human: [String.t()],
          deny: [String.t()]
        }
end
