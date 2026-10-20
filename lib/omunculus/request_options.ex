defmodule Omunculus.RequestOptions do
  @moduledoc "Store validation of replies and permission-bearing choices against their immutable original targets."
  alias Omunculus.Ceiling

  def validate(request, answer, linked?) do
    with :ok <- pending(request, linked?),
         :ok <- option(request, answer),
         :ok <- validate_parts(request, answer),
         do: :ok
  end

  defp pending(%{status: "escalated"}, false), do: {:error, {:reply, :escalated}}
  defp pending(%{status: "closed"}, _linked?), do: {:error, {:reply, :closed}}
  defp pending(_request, _linked?), do: :ok

  defp option(_request, answer) when not is_map_key(answer, "option"), do: :ok

  defp option(request, answer) do
    options = Jason.decode!(request.options)

    if is_binary(answer["option"]) and Map.has_key?(options, answer["option"]),
      do: :ok,
      else:
        {:error,
         {:reply, {:unknown_option, answer["option"], options |> Map.keys() |> Enum.sort()}}}
  end

  defp validate_parts(request, answer) do
    parts = Map.get(answer, "parts", %{})
    origins = Map.get(request, :origins, %{})

    if is_map(parts) and Map.keys(parts) -- Map.keys(origins) == [] do
      Enum.reduce_while(parts, :ok, fn {part, value}, :ok ->
        origin = origins[part]

        with true <- is_map(value) and Map.keys(value) -- ~w(body option parts) == [],
             true <- is_binary(value["body"]) and String.trim(value["body"]) != "",
             :ok <- validate(origin, value, true) do
          {:cont, :ok}
        else
          _ -> {:halt, {:error, {:reply, :invalid_parts}}}
        end
      end)
    else
      {:error, {:reply, :invalid_parts}}
    end
  end

  def authorize(_request, _answer, true), do: :ok

  def authorize(request, answer, false) do
    options = Jason.decode!(request.options)
    calls = options[answer["option"]] || []

    snapshot =
      if request[:requester_ceiling], do: Jason.decode!(request.requester_ceiling), else: nil

    sealed_grant =
      options
      |> Map.values()
      |> List.flatten()
      |> Enum.any?(fn call ->
        args = call["args"] || %{}
        call["name"] == "grant" and sealed?(snapshot, args["name"], args["kind"])
      end)

    refusal =
      if(sealed_grant, do: {:grant, :not_authorized}) ||
        Enum.find_value(calls, fn call ->
          args = call["args"] || %{}

          cond do
            call["name"] == "grant" and not is_nil(args["scope"]) ->
              {:grant, :not_human}

            sealed?(snapshot, call["name"], "tool") ->
              {:reply, :not_authorized}

            true ->
              nil
          end
        end)

    if refusal do
      {:error, refusal}
    else
      parts = answer["parts"]

      if is_map(parts) do
        Enum.reduce_while(parts, :ok, fn {part, value}, :ok ->
          if is_map(value) do
            case authorize(Map.get(Map.get(request, :origins, %{}), part), value, false) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          else
            {:cont, :ok}
          end
        end)
      else
        :ok
      end
    end
  end

  defp sealed?(nil, _name, _kind), do: false
  defp sealed?(snapshot, name, kind), do: Ceiling.classify(snapshot, name, kind) == "sealed"
end
