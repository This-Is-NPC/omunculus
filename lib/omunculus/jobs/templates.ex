defmodule Omunculus.Jobs.Templates do
  @moduledoc """
  The job templates of a pack, its `[jobs.<name>]` tables: what a pack
  imported with `omunculus pack` offers to schedule. A template holds the
  fields of a job (`Omunculus.Jobs.Fields`, but for `owner` and
  `conversation_id`, which belong to the project) and its `state`, `active`
  or `proposed`. The job it makes is named `<pack>.<template>`, so two packs
  never collide, and is owned by whoever imports the pack.

  The pack layer only hands them over: `emits/3` checks each against the
  config the pack imports into and returns the `job` emits that create
  those the store lacks, which `Omunculus.Jobs` applies like any create,
  with the channel `pack`.
  """

  alias Omunculus.Jobs.Fields

  @keys (Fields.keys() -- ~w(owner conversation_id)) ++ ["state"]
  @states ~w(active proposed)

  @doc """
  The `job` emits for the templates of `pack` (as `Omunculus.Config.Packs.read/1`
  returns it) that `existing` (the names of the jobs the project holds) lacks,
  or the first template that `config` refuses; `config` must have a `[jobs]` table.
  """
  @spec emits(map, Omunculus.Config.t(), [String.t()]) :: {:ok, [map]} | {:error, String.t()}
  def emits(pack, config, existing) do
    pack_name = pack["pack"]["name"]

    pack
    |> Map.get("jobs", %{})
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {template, table}, {:ok, emits} ->
      name = "#{pack_name}.#{template}"

      case check(name, table, config) do
        :ok ->
          emits = if(name in existing, do: emits, else: [emit(name, pack_name, table) | emits])
          {:cont, {:ok, emits}}

        {:error, reason} ->
          {:halt, {:error, "job template #{template}: #{reason}"}}
      end
    end)
    |> with_order()
  end

  defp with_order({:ok, emits}), do: {:ok, Enum.reverse(emits)}
  defp with_order(error), do: error

  defp check(name, %{} = table, config) do
    with [] <- Map.keys(table) -- @keys,
         true <- table["state"] in @states || {:error, "state is active or proposed"},
         :ok <- Fields.name(name),
         {:ok, input} <- Fields.input(Map.delete(table, "state"), config),
         {:ok, _fields} <- Fields.check(Map.merge(Fields.blank(), input), config) do
      :ok
    else
      [key | _] -> {:error, "unknown key #{key}"}
      {:error, {:jobs, _reason} = reason} -> {:error, Omunculus.Errors.format(reason)}
      {:error, _reason} = error -> error
    end
  end

  defp check(_name, _table, _config), do: {:error, "is not a table"}

  defp emit(name, pack_name, table) do
    body =
      Map.merge(table, %{
        "op" => "create",
        "name" => name,
        "channel" => "pack",
        "pack" => pack_name
      })

    %{"type" => "job", "body" => body}
  end
end
