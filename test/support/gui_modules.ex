defmodule Omunculus.GuiModules do
  @moduledoc """
  Runs assertions in `deno` against the pure `.pragma library` modules of the
  GUI client. Each module is bound to its file name (`Requests.js` becomes
  `Requests`) with its functions exported, as QML's `.import` gives it.
  """

  @client Path.expand("../../apps/kit/client", __DIR__)

  @doc "Runs `assertions` with `modules` loaded in order; returns deno's output and status."
  @spec run([String.t()], String.t()) :: {String.t(), non_neg_integer}
  def run(modules, assertions) do
    script = Enum.map_join(modules, "\n", &wrap/1) <> "\n" <> assertions
    System.cmd("deno", ["eval", script], stderr_to_stdout: true)
  end

  defp wrap(name) do
    source =
      @client
      |> Path.join(name <> ".js")
      |> File.read!()
      |> String.replace(~r/^\.pragma .*$/m, "")
      |> String.replace(~r/^\.import .*$/m, "")

    exports =
      ~r/^function (\w+)/m |> Regex.scan(source, capture: :all_but_first) |> List.flatten()

    "const #{name} = (() => {\n#{source}\nreturn {#{Enum.join(exports, ", ")}};\n})();"
  end
end
