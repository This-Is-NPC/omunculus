defmodule Omunculus.Store.Actions.Contract do
  @moduledoc "Validates the published emit fields before the store applies a batch."

  @fields %{
    "comment" => ~w(body work_id request_id inbox_id),
    "prompt" => ~w(message work_id),
    "work" => ~w(title work_id parent_id workspace),
    "request" => ~w(kind name reason),
    "reply" => ~w(request_id decision body scope),
    "continue" => [],
    "break" => ~w(body),
    "delegate" => ~w(title body workspace),
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

  defp forbidden(type, body) when type in ~w(work continue break delegate),
    do: Omunculus.Store.Actions.Helpers.ensure_no_forbidden(String.to_existing_atom(type), body)

  defp forbidden(_type, _body), do: :ok
  defp valid_value?(_key, nil), do: true
  defp valid_value?("ids", ids), do: is_list(ids) and Enum.all?(ids, &is_binary/1)
  defp valid_value?(_key, value), do: is_binary(value)
end
