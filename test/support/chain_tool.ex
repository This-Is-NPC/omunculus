defmodule Omunculus.Test.ChainTool do
  @moduledoc """
  The module behind the synthetic chaining tools of the tests. Outputs its
  own name, emits `args.emit`, chains `args.chain`, and fails when
  `args.fail` is true. `write/3` installs one such tool in a project.
  """

  @spec run(map) :: map
  def run(%{name: name, args: args}) do
    %{
      "ok" => Map.get(args, "fail") != true,
      "output" => name,
      "emit" => Map.get(args, "emit", []),
      "chain" => Map.get(args, "chain", [])
    }
  end

  @spec write(String.t(), String.t(), String.t()) :: :ok
  def write(dir, name, manifest) do
    tool_dir = Path.join([dir, "tools", name])
    File.mkdir_p!(tool_dir)

    File.write!(Path.join(tool_dir, "tool.toml"), """
    name = "#{name}"
    kind = "tool"
    module = "#{inspect(__MODULE__)}"
    #{manifest}
    """)
  end
end
