defmodule Omunculus.WorkItem do
  @moduledoc "The task definition handed between agents; identity and lifecycle belong to the harness."

  def schema do
    %{
      "type" => "object",
      "properties" => %{"instruction" => %{"type" => "string", "minLength" => 1}},
      "required" => ["instruction"],
      "additionalProperties" => false
    }
  end

  def validate(%{"instruction" => text} = item) when is_binary(text) and map_size(item) == 1 do
    if String.trim(text) == "", do: {:error, :invalid_work_item}, else: :ok
  end

  def validate(_), do: {:error, :invalid_work_item}

  def handoff(args) do
    with false <- Map.has_key?(args, "instruction"),
         :ok <- validate(args["work_item"]),
         comment when is_binary(comment) <- args["comment"],
         true <- String.trim(comment) != "" do
      {:ok, args["work_item"]}
    else
      _ -> {:error, :invalid_work_item_handoff}
    end
  end

  def from_activation(%{type: "task.requested", kind: :command, payload: p}),
    do: %{"instruction" => p["instruction"]}

  def from_activation(%{payload: p}), do: p["work_item"]

  def load(core, id) do
    [[instruction]] =
      Omunculus.EventCore.query(
        core,
        "SELECT instruction FROM WORK_ITEMS WHERE work_item_id = ?",
        [id]
      )

    %{"instruction" => instruction}
  end

  def render(item, comment) do
    "Work Item:\n" <>
      Jason.encode!(item) <>
      if(is_binary(comment) and comment != "", do: "\nComment:\n" <> comment, else: "")
  end
end
