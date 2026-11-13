defmodule Omunculus.Tools.Cites do
  @moduledoc """
  The runs a proposal cites as its reason (`propose_config`, `propose_job`):
  each must be one of the project's recent closed runs, named by its id or
  the start of it, and the request shows them.
  """

  @doc "The runs among `recent` that `ids` name, or the sentence that says one is not."
  @spec check(term, [map]) :: {:ok, [map]} | String.t()
  def check(nil, _recent), do: {:ok, []}

  def check(ids, recent) when is_list(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      found = is_binary(id) and id != "" && Enum.find(recent, &String.starts_with?(&1.id, id))

      if found,
        do: {:cont, {:ok, acc ++ [found]}},
        else:
          {:halt,
           "no run #{inspect(id)} among the last #{length(recent)} closed runs; read them with runs"}
    end)
  end

  def check(_ids, _recent), do: "runs is a list of run ids"

  @doc "The lines of a request's reason that cite `runs`."
  @spec line([map]) :: String.t()
  def line([]), do: "runs cited: none"

  def line(cited) do
    "runs cited:\n" <>
      Enum.map_join(cited, "\n", fn run ->
        "- #{run.id}, #{run.agent}" <>
          if(run.work_title, do: ", work #{run.work_title}", else: "")
      end)
  end
end
