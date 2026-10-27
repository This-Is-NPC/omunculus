defmodule Omunculus.Test.CounterTool do
  @moduledoc """
  The `counter` tool of the tests: outputs how many `counter` calls its run
  has recorded, this one included. `write/1` installs it in a project;
  `value/1` counts the committed `counter` calls of the store.
  """

  alias Omunculus.Store.Query

  @spec run(map) :: map
  def run(%{view: %{"events" => events}}),
    do: %{"ok" => true, "output" => Integer.to_string(count(events) + 1), "emit" => []}

  @spec write(String.t()) :: :ok
  def write(dir) do
    tool_dir = Path.join([dir, "tools", "counter"])
    File.mkdir_p!(tool_dir)

    File.write!(Path.join(tool_dir, "tool.toml"), """
    name = "counter"
    kind = "tool"
    triggers = ["model"]
    description = "Increments the counter and returns its value."
    module = "#{inspect(__MODULE__)}"

    [parameters]
    type = "object"

    [views.events]
    source = "events"
    relation = "run"
    """)
  end

  @spec value(Omunculus.Store.Connection.t()) :: non_neg_integer
  def value(conn) do
    {:ok, events} = Query.all(conn, "SELECT type, body FROM events WHERE type = 'tool'")
    count(events)
  end

  defp count(events),
    do: Enum.count(events, &(&1.type == "tool" and Jason.decode!(&1.body)["name"] == "counter"))
end
