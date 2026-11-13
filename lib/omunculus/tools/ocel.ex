defmodule Omunculus.Tools.Ocel do
  @moduledoc """
  Builtin `ocel` tool, from the command line only: the project's event log
  as OCEL 2.0 JSON (`Omunculus.Process.Ocel`), printed or, with `out`,
  written to that path, relative to the project's folder.
  """

  alias Omunculus.Process.{Log, Ocel}
  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, view: view, config_path: config_path}) do
    with {:ok, _last} <- Args.count_text(args, "last") do
      json = view["log"] |> Log.build() |> Ocel.encode() |> Jason.encode!(pretty: true)

      case Args.present(args, "out") do
        nil -> Out.ok(json)
        out -> write(Path.expand(out, Path.dirname(config_path)), json)
      end
    else
      {:error, message} -> Out.fail(message)
    end
  end

  defp write(path, json) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, json) do
      Out.ok("wrote #{path}")
    else
      {:error, reason} -> Out.fail("could not write #{path}: #{:file.format_error(reason)}")
    end
  end
end
