defmodule Omunculus.Runtime.Prompt do
  @moduledoc "Configured agent identity and the shared response contract."

  def compose(name, role) do
    """
    You are #{name}.
    #{role}

    #{Omunculus.Runtime.Report.instruction()}
    """
  end
end
