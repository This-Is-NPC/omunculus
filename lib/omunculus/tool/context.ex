defmodule Omunculus.Tool.Context do
  @moduledoc false

  defstruct fs: nil, options: %{}, state: %{}

  @type t :: %__MODULE__{fs: map(), options: map(), state: map()}

  def new(fs, options \\ %{}), do: %__MODULE__{fs: fs, options: options}

  def tool_options(%__MODULE__{options: options}, name),
    do: get_in(options, [:tools, name]) || %{}

  def tool_state(%__MODULE__{state: state}, name, default),
    do: Map.get(state, name, default)

  def put_tool_state(%__MODULE__{} = context, name, value),
    do: %{context | state: Map.put(context.state, name, value)}
end
