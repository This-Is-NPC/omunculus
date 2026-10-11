defmodule Omunculus.Store.Actions.Contract do
  @moduledoc "Validates the published emit fields before the store applies a batch."

  @forbidden ~w(stage agent model)

  @fields %{
    "comment" => ~w(body work_id request_id inbox_id),
    "prompt" => ~w(message work_id agent),
    "work" => ~w(report works),
    "request" => ~w(reason options to),
    "reply" => ~w(request_id option body),
    "grant" => ~w(request_id name kind scope),
    "cancel" => ~w(request_id),
    "continue" => [],
    "end" => [],
    "break" => ~w(body),
    "reopen" => ~w(work_id body agent stage grant),
    "delegate" => ~w(title goal agent workspace),
    "notify" => ~w(body work_id),
    "inbox.read" => ~w(inbox_id),
    "compact" => ~w(work_id request_id inbox_id summary ids),
    "comment.delete" => ~w(work_id request_id inbox_id ids)
  }

  def validate(%{"type" => type, "body" => body} = emit) when is_map(body) do
    with {:ok, fields} <- fields(type),
         :ok <- keys(emit, ~w(type body), type),
         :ok <- forbidden(type, body),
         :ok <- keys(body, fields, type) do
      Enum.reduce_while(body, :ok, fn {key, value}, :ok ->
        if valid_value?(key, value),
          do: {:cont, :ok},
          else: {:halt, {:error, {:invalid_emit, type, {:invalid, key}}}}
      end)
    end
  end

  def validate(_emit), do: {:error, :invalid_emit}

  defp fields(type) do
    case Map.fetch(@fields, type) do
      {:ok, fields} -> {:ok, fields}
      :error -> {:error, {:unknown_action, type}}
    end
  end

  defp keys(map, fields, type) do
    case Map.keys(map) -- fields do
      [] -> :ok
      [key | _] -> {:error, {:invalid_emit, type, {:unknown_field, key}}}
    end
  end

  # A body never names the stage, agent or model the TOML decides; a
  # `delegate`, and each of the `works` of a `work`, may name the new work's
  # agent, checked against the TOML.
  defp forbidden(type, body) when type in ~w(work continue break delegate) do
    keys = if type == "delegate", do: @forbidden -- ["agent"], else: @forbidden

    case Enum.find(keys, &Map.has_key?(body, &1)) do
      nil -> :ok
      key -> {:error, {String.to_existing_atom(type), {:forbidden, key}}}
    end
  end

  defp forbidden(_type, _body), do: :ok

  defp valid_value?(_key, nil), do: true
  defp valid_value?("ids", ids), do: is_list(ids) and Enum.all?(ids, &is_binary/1)
  defp valid_value?("options", options), do: is_map(options)
  defp valid_value?("works", works), do: is_list(works)

  defp valid_value?("grant", grant),
    do:
      is_list(grant) and
        Enum.all?(
          grant,
          &match?(%{"kind" => k, "name" => n} when is_binary(k) and is_binary(n), &1)
        )

  defp valid_value?(_key, value), do: is_binary(value)
end
