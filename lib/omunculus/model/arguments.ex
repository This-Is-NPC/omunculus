defmodule Omunculus.Model.Arguments do
  @moduledoc """
  A tool call's arguments as a provider sends them: an object, its JSON
  text, or nothing. Arguments that are not a JSON object are told to the
  model as the call's result, so it can call again.
  """

  alias Omunculus.Tools.Out

  @spec decode(term) :: {:ok, map} | {:error, String.t()}
  def decode(arguments) when is_map(arguments), do: {:ok, arguments}
  def decode(arguments) when arguments in [nil, ""], do: {:ok, %{}}

  def decode(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _not_an_object -> {:error, Out.invalid_arguments()}
    end
  end

  def decode(_arguments), do: {:error, Out.invalid_arguments()}
end
