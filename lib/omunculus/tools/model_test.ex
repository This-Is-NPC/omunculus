defmodule Omunculus.Tools.ModelTest do
  @moduledoc """
  Builtin `model_test` tool: whether a model answers. It sends one short
  prompt, without tools, to the model `name` — as the config holds it,
  or as `value`, its table in JSON, before it is saved — with the
  credential its provider resolves, and prints `{reply, ms}`, or the
  reason it failed. A `command` model runs in the sandbox an agent's
  ceiling makes, so only a run tests it.
  """

  alias Omunculus.{CLI, Config}
  alias Omunculus.Tools.Out

  @prompt "This is a connection test. Reply with the single word: ok"

  @spec run(map) :: map
  def run(%{config_path: path, args: %{"name" => name} = args})
      when is_binary(path) and is_binary(name) do
    with {:ok, config} <- config(path, name, args["value"]),
         {:ok, spec} <- fetch(config, name),
         :ok <- testable(spec),
         {:ok, model} <- Config.model(config, name) do
      started = System.monotonic_time(:millisecond)

      case model.(@prompt, [], &no_tools/2, fn _event -> :ok end, fn _text -> :ok end, nil) do
        {:ok, reply} ->
          ms = System.monotonic_time(:millisecond) - started
          Out.ok(Jason.encode!(%{reply: reply, ms: ms}))

        {:error, reason} ->
          Out.fail(CLI.format_error(reason))
      end
    else
      {:error, reason} -> Out.fail(CLI.format_error(reason))
    end
  end

  def run(_input), do: Out.fail("config_path and name required")

  defp config(path, _name, nil), do: Config.load(path)

  defp config(path, name, value) do
    case Jason.decode(value) do
      {:ok, table} -> Config.try_item(path, {"models", name}, table)
      {:error, _invalid} -> {:error, {:config, :invalid_item}}
    end
  end

  defp fetch(config, name) do
    case Map.fetch(config.models, name) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, {:model_test, :unknown, name}}
    end
  end

  defp testable(%{api: "command"}), do: {:error, {:model_test, :command}}
  defp testable(_spec), do: :ok

  defp no_tools(name, _args), do: {:error, "#{name}: a model test has no tools"}
end
