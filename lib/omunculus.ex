defmodule Omunculus do
  @moduledoc """
  Coding-agent harness: one directory, one instruction, filesystem tools.
  """

  def version do
    case Application.spec(:omunculus, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      _ -> "0.1.0"
    end
  end
end
