defmodule Omunculus.Tools.ProposeConfig do
  @moduledoc """
  Builtin `propose_config` tool: loads the config `config_path` would make
  once `item` is `value` laid over what the file holds for it
  (`Omunculus.Config.try_item/3`) and, when it loads, emits a request, to
  whoever gave the agent its work, whose `apply` option calls `configure`
  with the item so written at the file's current revision, and whose
  `deny` calls nothing.

  `value` is a patch: a key it gives replaces the file's (a list whole, a
  table key by key), a key it gives as `null` is removed, and a key it
  leaves out stays. `null` as `value` removes the item. The request's
  reason gives the agent's `reason`, the runs it cites and the item as the
  config runs it, before and after, logins' keys left out.

  A change that does not load fails here, with why, and so does an agent
  whose tools chain a step it lacks (`Omunculus.Tools.Steps`), a run id
  cited that is not among the project's recent runs, a change that leaves
  the item as it is, and one the person already refused in the
  conversation. Its manifest's `then` appends `end`.
  """

  alias Omunculus.Config
  alias Omunculus.Config.Toml, as: ConfigToml
  alias Omunculus.Tools.{Args, Out, Steps}
  alias Omunculus.Tools.Config, as: ConfigTool

  @spec run(map) :: map
  def run(%{args: args, config_path: path} = input) when is_binary(path) do
    view = Map.get(input, :view) || %{}

    with nil <- Args.missing(args, ~w(item reason)),
         item = Config.item(args["item"]),
         {:ok, %{document: document, revision: revision}} <- Config.document(path),
         {:ok, cited} <- cited(args["runs"], view["recent"] || []),
         held = get_in(document, Tuple.to_list(item)),
         value = patch(Map.get(args, "value"), held, document, item, args["from"]),
         :ok <- changes(value, held),
         :ok <- not_refused(view["answered"] || [], args, value),
         {:ok, before} <- Config.load(path),
         {:ok, config} <- Config.try_item(path, item, value),
         [] <- steps(config, item, value) do
      Out.ok("", [
        %{
          "type" => "request",
          "body" =>
            request(
              args,
              value,
              revision,
              cited,
              {shown(before, item, held), shown(config, item, value)}
            )
        }
      ])
    else
      {:error, reason} -> Out.fail("the config would not load: #{inspect(reason)}")
      [_ | _] = missing -> Out.fail("the agent would be refused:\n" <> Enum.join(missing, "\n"))
      message -> Out.fail(message)
    end
  end

  def run(_input), do: Out.fail("config_path required")

  # The patch laid over the table the file holds, or over the renamed
  # item's when `from` names it; nil removes the item.
  defp patch(nil, _held, _document, _item, _from), do: nil

  defp patch(%{} = value, held, document, item, from) do
    base = if from, do: get_in(document, [elem(item, 0), from]), else: held
    merge(base || %{}, value)
  end

  defp patch(value, _held, _document, _item, _from), do: value

  defp merge(base, patch) do
    Enum.reduce(patch, base, fn
      {key, nil}, acc -> Map.delete(acc, key)
      {key, %{} = table}, acc -> Map.put(acc, key, merge(table_of(acc[key]), table))
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp table_of(%{} = table), do: table
  defp table_of(_value), do: %{}

  defp changes(value, held),
    do: if(value == held, do: "the file already holds this item as proposed", else: :ok)

  # A proposal that comes to what the person refused in this conversation.
  defp not_refused(answered, args, value) do
    refused =
      Enum.find(answered, fn request ->
        request.answer != "apply" and proposes?(request, args, value)
      end)

    case refused do
      nil -> :ok
      request -> "the person already refused this change: #{request.reply}"
    end
  end

  defp proposes?(request, args, value) do
    case request.options |> Jason.decode!() |> Map.get("apply") do
      [%{"name" => "configure", "args" => configure}] ->
        configure["item"] == args["item"] and configure["from"] == args["from"] and
          Jason.decode!(configure["value"]) == value

      _other ->
        false
    end
  end

  # The runs cited, each one of the project's recent runs, by id or its start.
  defp cited(nil, _recent), do: {:ok, []}

  defp cited(ids, recent) when is_list(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      found = is_binary(id) and id != "" && Enum.find(recent, &String.starts_with?(&1.id, id))

      if found,
        do: {:cont, {:ok, acc ++ [found]}},
        else:
          {:halt,
           "no run #{inspect(id)} among the last #{length(recent)} closed runs; read them with runs"}
    end)
  end

  defp cited(_ids, _recent), do: "runs is a list of run ids"

  defp steps(config, {"agents", name}, value) when not is_nil(value),
    do: Steps.missing(config, [name])

  defp steps(_config, _item, _value), do: []

  defp request(args, value, revision, cited, {was, would_be}) do
    configure =
      %{"item" => args["item"], "value" => Jason.encode!(value), "revision" => revision}
      |> Args.put_present("from", args)

    %{
      "reason" =>
        Enum.join(
          [
            args["reason"],
            runs_line(cited),
            "#{args["item"]} as it runs now:\n" <> was,
            "#{args["item"]} as it would run:\n" <> would_be
          ],
          "\n\n"
        ),
      "options" => %{
        "apply" => [%{"name" => "configure", "args" => configure}],
        "deny" => []
      }
    }
  end

  defp runs_line([]), do: "runs cited: none"

  defp runs_line(cited) do
    "runs cited:\n" <>
      Enum.map_join(cited, "\n", fn run ->
        "- #{run.id}, #{run.agent}" <>
          if(run.work_title, do: ", work #{run.work_title}", else: "")
      end)
  end

  # The item as the config runs it, in the file's own notation; what a
  # computed item leaves empty or off is not shown.
  defp shown(config, item, table) do
    case ConfigTool.effective(config, item) do
      :file -> render(item, table, &is_nil/1)
      effective -> render(item, effective, &(is_nil(&1) or &1 in [[], false]))
    end
  end

  defp render(_item, nil, _blank), do: "(none)"

  defp render(item, table, blank) do
    table = table |> Jason.encode!() |> Jason.decode!() |> compact(blank)
    ConfigToml.encode(put_in(%{}, Enum.map(Tuple.to_list(item), &Access.key(&1, %{})), table))
  end

  defp compact(%{} = map, blank) do
    map
    |> Enum.reject(fn {_key, value} -> blank.(value) end)
    |> Map.new(fn {key, value} -> {key, compact(value, blank)} end)
  end

  defp compact(list, blank) when is_list(list), do: Enum.map(list, &compact(&1, blank))
  defp compact(value, _blank), do: value
end
