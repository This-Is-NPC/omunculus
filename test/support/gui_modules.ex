defmodule Omunculus.GuiModules do
  @moduledoc """
  Runs assertions in `deno` against the pure `.pragma library` modules of the
  GUI client. Each module is bound to its file name (`Requests.js` becomes
  `Requests`) with its top-level functions and constants exported, as QML's
  `.import` gives it.
  """

  # The client's pure modules, and the ui's own (`Colour.js`, which the theme imports).
  @folders [
    Path.expand("../../apps/kit/client", __DIR__),
    Path.expand("../../apps/kit/ui", __DIR__)
  ]

  @doc "Runs `assertions` with `modules` loaded in order, under `env`; returns deno's output and status."
  @spec run([String.t()], String.t(), [{String.t(), String.t()}]) :: {String.t(), non_neg_integer}
  def run(modules, assertions, env \\ []) do
    script = Enum.map_join(modules, "\n", &wrap/1) <> "\n" <> assertions
    System.cmd("deno", ["eval", script], env: env, stderr_to_stdout: true)
  end

  defp wrap(name) do
    source =
      @folders
      |> Enum.map(&Path.join(&1, name <> ".js"))
      |> Enum.find(&File.exists?/1)
      |> File.read!()
      |> String.replace(~r/^\.pragma .*$/m, "")
      |> String.replace(~r/^\.import .*$/m, "")

    exports =
      ~r/^(?:function|const) (\w+)/m
      |> Regex.scan(source, capture: :all_but_first)
      |> List.flatten()

    "const #{name} = (() => {\n#{source}\nreturn {#{Enum.join(exports, ", ")}};\n})();"
  end
end
