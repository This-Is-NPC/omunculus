defmodule Omunculus.Jobs.Cost do
  @moduledoc """
  What the runs of a fire used: the model calls they made, the tokens and the
  dollars at the models' prices (`Omunculus.Usage`). The runs of a fire are
  those caused by the events it wrote and, transitively, by the runs below.
  """

  alias Omunculus.{Config, Usage}
  alias Omunculus.Store.Query

  @type t :: %{calls: non_neg_integer, input_tokens: integer, output_tokens: integer, usd: float}

  @runs """
  WITH RECURSIVE caused(id) AS (
    SELECT id FROM runs WHERE cause_id IN (%{seeds})
    UNION
    SELECT runs.id FROM runs
    JOIN events ON events.id = runs.cause_id
    JOIN caused ON events.run_id = caused.id)
  """

  @doc "The ids of the runs the events `event_ids` caused, oldest first."
  @spec runs(Omunculus.Store.Connection.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term}
  def runs(_conn, []), do: {:ok, []}

  def runs(conn, event_ids) do
    sql =
      String.replace(@runs, "%{seeds}", Query.placeholders(event_ids)) <>
        "SELECT runs.id FROM runs WHERE runs.id IN caused ORDER BY runs.started_at, runs.id"

    with {:ok, rows} <- Query.all(conn, sql, event_ids), do: {:ok, Enum.map(rows, & &1.id)}
  end

  @doc "The usage of the model replies the runs `run_ids` recorded."
  @spec of_runs(Omunculus.Store.Connection.t(), Config.t(), [String.t()]) ::
          {:ok, t} | {:error, term}
  def of_runs(_conn, _config, []),
    do: {:ok, %{calls: 0, input_tokens: 0, output_tokens: 0, usd: 0.0}}

  def of_runs(conn, config, run_ids) do
    with {:ok, rows} <-
           Query.all(
             conn,
             "SELECT runs.agent AS agent, events.body AS body FROM events JOIN runs ON runs.id = events.run_id WHERE events.type = 'model' AND events.run_id IN (#{Query.placeholders(run_ids)})",
             run_ids
           ) do
      {:ok,
       Enum.reduce(
         rows,
         %{calls: 0, input_tokens: 0, output_tokens: 0, usd: 0.0},
         &add(&2, &1, config)
       )}
    end
  end

  defp add(total, row, config) do
    reply = Usage.reply(row.body)
    sum = Usage.sum([reply])
    model = reply["model"] || get_in(config.agents, [row.agent, Access.key(:model)])
    price = config.models |> Map.get(model, %{}) |> Map.get(:price)

    %{
      calls: total.calls + 1,
      input_tokens: total.input_tokens + trunc(sum.input),
      output_tokens: total.output_tokens + trunc(sum.output),
      usd: total.usd + if(price, do: Usage.spend(sum, price), else: 0.0)
    }
  end
end
