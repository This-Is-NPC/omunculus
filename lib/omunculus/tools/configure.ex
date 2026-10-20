defmodule Omunculus.Tools.Configure do
  @moduledoc """
  Builtin `configure` tool: writes one item of the project's TOML through
  `Omunculus.Config.edit/5`. `item` is `<section>.<name>` (`agents`,
  `models`, `workflows`, `workspaces`, `auth`, `secrets`) or `policy` /
  `access`;
  `value` is its table in JSON, or `null` to remove it; `from`, an item
  of the same section renamed to it. The file must still be at
  `revision`, the one `config` printed, and the result must load;
  otherwise it stays as it is.
  """

  alias Omunculus.{CLI, Config}
  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(%{
        config_path: path,
        args: %{"item" => item, "value" => value, "revision" => revision} = args
      })
      when is_binary(path) and is_binary(item) and is_binary(value) and is_binary(revision) do
    with {:ok, value} <- Jason.decode(value),
         :ok <- Config.edit(path, revision, Config.item(item), value, args["from"]) do
      Out.ok()
    else
      {:error, %Jason.DecodeError{}} -> Out.fail(CLI.format_error({:config, :invalid_item}))
      {:error, reason} -> Out.fail(CLI.format_error(reason))
    end
  end

  def run(_input), do: Out.fail("config_path, item, value and revision required")
end
