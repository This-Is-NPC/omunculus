defmodule Omunculus.Tools.Out do
  @moduledoc """
  Builds the `out` map every builtin tool and hook returns.
  """

  @spec ok(String.t(), [map]) :: map
  def ok(output \\ "", emit \\ []) do
    %{"ok" => true, "output" => output, "emit" => emit}
  end

  @spec fail(String.t()) :: map
  def fail(message) do
    %{"ok" => false, "output" => message, "emit" => []}
  end
end
