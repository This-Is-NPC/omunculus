defmodule Omunculus.Execution.Command do
  @moduledoc """
  Represents a command without shell interpolation.
  """

  @enforce_keys [:program]
  defstruct [:program, args: [], cwd: nil]

  @type t :: %__MODULE__{program: String.t(), args: [String.t()], cwd: String.t() | nil}

  @spec new(String.t(), [String.t()], keyword) :: {:ok, t} | {:error, term}
  def new(program, args \\ [], options \\ []) do
    command = %__MODULE__{program: program, args: args, cwd: Keyword.get(options, :cwd)}

    if valid?(command), do: {:ok, command}, else: {:error, :invalid_command}
  end

  @spec valid?(t) :: boolean
  def valid?(%__MODULE__{program: program, args: args, cwd: cwd}) do
    is_binary(program) and Path.type(program) == :absolute and
      is_list(args) and Enum.all?(args, &is_binary/1) and
      (is_nil(cwd) or (is_binary(cwd) and Path.type(cwd) == :absolute))
  end
end
