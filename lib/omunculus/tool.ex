defmodule Omunculus.Tool do
  @moduledoc false

  @callback name() :: String.t()
  @callback schema() :: map()
  @callback call(args :: map(), context :: Omunculus.Tool.Context.t()) ::
              {:ok, String.t(), Omunculus.Tool.Context.t()}
              | {:error, term(), Omunculus.Tool.Context.t()}

  def openai_function(mod) when is_atom(mod) do
    schema = mod.schema()

    %{
      "type" => "function",
      "function" => %{
        "name" => schema["name"],
        "description" => schema["description"],
        "parameters" => schema["parameters"]
      }
    }
  end
end
