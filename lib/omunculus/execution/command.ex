defmodule Omunculus.Execution.Command do
  @moduledoc """
  Represents a command without shell interpolation, and the secrets its
  process alone receives: values by name, which the backend hands to it as
  files and nothing records. A `script` is the text a shell program runs,
  which the backend hands over as a file: its text is then on no process's
  command line, so a pattern from it (`pkill -f`) matches only what the
  script itself started.
  """

  @derive {Inspect, except: [:secrets]}
  @enforce_keys [:program]
  defstruct [:program, args: [], cwd: nil, secrets: %{}, script: nil]

  @type t :: %__MODULE__{
          program: String.t(),
          args: [String.t()],
          cwd: String.t() | nil,
          secrets: %{String.t() => String.t()},
          script: String.t() | nil
        }

  @spec new(String.t(), [String.t()], keyword) :: {:ok, t} | {:error, term}
  def new(program, args \\ [], options \\ []) do
    command = %__MODULE__{
      program: program,
      args: args,
      cwd: Keyword.get(options, :cwd),
      secrets: Keyword.get(options, :secrets, %{}),
      script: Keyword.get(options, :script)
    }

    if valid?(command), do: {:ok, command}, else: {:error, :invalid_command}
  end

  @spec valid?(t) :: boolean
  def valid?(%__MODULE__{program: program, args: args, cwd: cwd, secrets: secrets, script: script}) do
    is_binary(program) and Path.type(program) == :absolute and
      is_list(args) and Enum.all?(args, &is_binary/1) and
      (is_nil(cwd) or (is_binary(cwd) and Path.type(cwd) == :absolute)) and
      is_map(secrets) and Enum.all?(secrets, &secret?/1) and
      (is_nil(script) or is_binary(script))
  end

  @doc "Whether `name` can name a secret: an environment variable's name."
  @spec secret_name?(term) :: boolean
  def secret_name?(name), do: is_binary(name) and name =~ ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  defp secret?({name, value}), do: secret_name?(name) and is_binary(value)
end
