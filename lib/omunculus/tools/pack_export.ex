defmodule Omunculus.Tools.PackExport do
  @moduledoc """
  `pack export` tool: writes the pack in `path` as an `.omupack`
  (`Omunculus.Config.Omupack`) to `out`, and says its path and sha256.
  `path` and `out` are relative to the directory of the config path, the
  working directory for the command line.
  """

  alias Omunculus.Errors
  alias Omunculus.Config.Omupack
  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, config_path: config_path}) when is_binary(config_path) do
    base = Path.dirname(config_path)

    with nil <- Args.missing(args, ~w(path)),
         {:ok, file, sha256} <- Omupack.export(Path.expand(args["path"], base), args["out"], base) do
      Out.ok("#{file}\nsha256 #{sha256}")
    else
      {:error, {_name, kind, _detail} = reason} when kind in [:omunculus, :header] ->
        Out.fail("cannot export #{args["path"]}: #{Errors.format({:packs, reason})}")

      {:error, reason} when is_binary(reason) ->
        Out.fail("cannot export #{args["path"]}: #{reason}")

      {:error, reason} ->
        Out.fail("cannot export #{args["path"]}: #{inspect(reason)}")

      message ->
        Out.fail(message)
    end
  end

  def run(_input), do: Out.fail("config_path required")
end
