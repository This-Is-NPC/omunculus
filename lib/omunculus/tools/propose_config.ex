defmodule Omunculus.Tools.ProposeConfig do
  @moduledoc """
  Builtin `propose_config` tool: loads the config `config_path` would make
  once `item` is `value` (`Omunculus.Config.try_item/3`) and, when it loads,
  emits a request whose `apply` option calls `configure` with that change
  at the file's current revision, and whose `deny` calls nothing; its
  reason gives the agent's `reason` and the item as it is and as it would
  be, logins' keys left out. A change that does not load fails here, with
  why. Its manifest's `then` appends `end`.
  """

  alias Omunculus.Config
  alias Omunculus.Config.Toml, as: ConfigToml
  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, config_path: path}) when is_binary(path) do
    with nil <- Args.missing(args, ~w(item reason)),
         item = Config.item(args["item"]),
         value = Map.get(args, "value"),
         {:ok, _config} <- Config.try_item(path, item, value),
         {:ok, %{document: document, revision: revision}} <- Config.document(path) do
      Out.ok("", [
        %{"type" => "request", "body" => request(args, item, value, document, revision)}
      ])
    else
      {:error, reason} -> Out.fail("the config would not load: #{inspect(reason)}")
      message -> Out.fail(message)
    end
  end

  def run(_input), do: Out.fail("config_path required")

  defp request(args, item, value, document, revision) do
    configure =
      %{"item" => args["item"], "value" => Jason.encode!(value), "revision" => revision}
      |> Args.put_present("from", args)

    %{
      "reason" =>
        Enum.join(
          [
            args["reason"],
            "#{args["item"]} as it is:\n" <> shown(item, get_in(document, Tuple.to_list(item))),
            "#{args["item"]} as it would be:\n" <> shown(item, value)
          ],
          "\n\n"
        ),
      "options" => %{
        "apply" => [%{"name" => "configure", "args" => configure}],
        "deny" => []
      }
    }
  end

  defp shown(_item, nil), do: "(none)"

  defp shown(item, table),
    do: ConfigToml.encode(put_in(%{}, Enum.map(Tuple.to_list(item), &Access.key(&1, %{})), table))
end
