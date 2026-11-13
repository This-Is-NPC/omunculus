defmodule Omunculus.Jobs.Fields do
  @moduledoc """
  What a job holds besides its name and its state, read from arguments and
  checked against the project's config and its `[jobs]` policy
  (`Omunculus.Jobs.Policy`). Pure: the store's own rules (names taken, the
  jobs a project may hold, a conversation that exists) are
  `Omunculus.Jobs`'s.

  A job aims at exactly one target: an `agent` (of depth 0, which can run
  without a work) or a `workflow`, each given a `message`; or a `tool` called
  with `args` and no model. `schedule` and `timezone` say when
  (`Omunculus.Jobs.Schedule`). `conversation_id` fixes the conversation its
  fires go to (without it each fire opens its own), `workspace` the workspace
  they work in, `condition` a tool, given `condition_args`, that gates each
  fire, and `end_at` the instant after which none fires. `owner` is the
  identity its fires act as: an `[accounts]` name or an agent's name.
  `delivery` is `owner_inbox` to have each fire's final agent reply arrive in
  the owner's mailbox as a message from the job (`Omunculus.Jobs.messages/2`),
  or empty for none.
  """

  alias Omunculus.{Accounts, Participant}
  alias Omunculus.Jobs.Schedule

  @fields ~w(agent workflow tool args message schedule timezone conversation_id workspace condition condition_args end_at owner delivery)
  @maps ~w(args condition_args)
  @name ~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/

  @spec keys() :: [String.t()]
  def keys, do: @fields

  @spec blank() :: %{String.t() => nil}
  def blank, do: Map.new(@fields, &{&1, nil})

  @doc "Whether `name` is a job's name: letters, digits, `.`, `_` and `-`, at most 64."
  @spec name(term) :: :ok | {:error, term}
  def name(name) when is_binary(name),
    do: if(name =~ @name, do: :ok, else: {:error, {:jobs, {:invalid, "name"}}})

  def name(_name), do: {:error, {:jobs, {:invalid, "name"}}}

  @doc """
  The fields `attrs` gives, typed: an empty text clears a field, an object
  may be written as JSON, and `owner` is resolved to an identity.
  """
  @spec input(map, Omunculus.Config.t()) :: {:ok, map} | {:error, term}
  def input(attrs, config) do
    attrs
    |> Map.take(@fields)
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case cast(key, blank_to_nil(value), config) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp cast(_key, nil, _config), do: {:ok, nil}

  defp cast(key, value, _config) when key in @maps do
    case value do
      %{} -> {:ok, value}
      text when is_binary(text) -> decode(key, text)
      _other -> {:error, {:jobs, {:invalid, key}}}
    end
  end

  defp cast("owner", %{} = identity, _config) do
    if Participant.valid?(identity),
      do: {:ok, identity},
      else: {:error, {:jobs, {:invalid, "owner"}}}
  end

  defp cast("owner", name, config) when is_binary(name) do
    case Accounts.identity(config, name) do
      {:ok, identity} -> {:ok, identity}
      :error -> {:error, {:jobs, {:unknown_account, name}}}
    end
  end

  defp cast(key, value, _config) when is_binary(value) and key != "owner",
    do: {:ok, String.trim(value)}

  defp cast(key, _value, _config), do: {:error, {:jobs, {:invalid, key}}}

  defp decode(key, text) do
    case Jason.decode(text) do
      {:ok, %{} = object} -> {:ok, object}
      _other -> {:error, {:jobs, {:invalid, key}}}
    end
  end

  @doc """
  Checks `fields`, every key of `keys/0` present, and returns them
  normalized; the schedule must have a fire and may not fire more often than
  `[jobs] min_interval_minutes` allows.
  """
  @spec check(map, Omunculus.Config.t()) :: {:ok, map} | {:error, term}
  def check(fields, config) do
    with :ok <- target(fields, config),
         {:ok, fields} <- payload(fields),
         {:ok, fields} <- condition(fields),
         :ok <- workspace(fields["workspace"], config),
         :ok <- schedule(fields, config),
         {:ok, fields} <- end_at(fields),
         :ok <- delivery(fields["delivery"]),
         :ok <- owner(fields["owner"]) do
      {:ok, fields}
    end
  end

  defp target(fields, config) do
    case Enum.reject(~w(agent workflow tool), &is_nil(fields[&1])) do
      ["agent"] -> agent(fields["agent"], config)
      ["workflow"] -> known(config.workflows, fields["workflow"], :unknown_workflow)
      ["tool"] -> :ok
      _ -> {:error, {:jobs, :one_target}}
    end
  end

  defp agent(name, config) do
    case config.agents do
      %{^name => %{depth: 0, workflow_only: false}} -> :ok
      _ -> {:error, {:jobs, {:unknown_agent, name}}}
    end
  end

  defp known(table, name, tag),
    do: if(Map.has_key?(table, name), do: :ok, else: {:error, {:jobs, {tag, name}}})

  defp payload(%{"tool" => tool} = fields) when is_binary(tool) do
    if fields["message"],
      do: {:error, {:jobs, {:invalid, "message"}}},
      else: {:ok, Map.update!(fields, "args", &(&1 || %{}))}
  end

  defp payload(fields) do
    cond do
      fields["args"] -> {:error, {:jobs, {:invalid, "args"}}}
      String.trim(fields["message"] || "") == "" -> {:error, {:jobs, {:invalid, "message"}}}
      true -> {:ok, Map.update!(fields, "message", &String.trim/1)}
    end
  end

  defp condition(%{"condition" => nil, "condition_args" => args} = fields)
       when args in [nil, %{}],
       do: {:ok, %{fields | "condition_args" => nil}}

  defp condition(%{"condition" => nil}), do: {:error, {:jobs, {:invalid, "condition_args"}}}
  defp condition(fields), do: {:ok, Map.update!(fields, "condition_args", &(&1 || %{}))}

  defp workspace(nil, _config), do: :ok
  defp workspace(name, config), do: known(config.workspaces, name, :unknown_workspace)

  defp schedule(%{"schedule" => text, "timezone" => timezone}, config)
       when is_binary(text) and is_binary(timezone) do
    with {:ok, schedule} <- parse(text, timezone),
         [_first | _] <- Schedule.next_fires(schedule, 1) do
      limit = config.jobs.min_interval_minutes * 60

      case Schedule.min_interval(schedule) do
        gap when is_integer(gap) and gap < limit -> {:error, {:jobs, {:too_frequent, gap, limit}}}
        _ -> :ok
      end
    else
      [] -> {:error, {:jobs, {:invalid, "schedule"}}}
      {:error, _reason} = error -> error
    end
  end

  defp schedule(%{"schedule" => text}, _config) when not is_binary(text),
    do: {:error, {:jobs, {:invalid, "schedule"}}}

  defp schedule(_fields, _config), do: {:error, {:jobs, {:invalid, "timezone"}}}

  @doc "The schedule `text` in `timezone`, with the reason it is refused."
  @spec parse(String.t(), String.t()) :: {:ok, Schedule.t()} | {:error, term}
  def parse(text, timezone) do
    case Schedule.parse(text, timezone) do
      {:ok, schedule} -> {:ok, schedule}
      {:error, {:unknown_timezone, name}} -> {:error, {:jobs, {:unknown_timezone, name}}}
      {:error, _reason} -> {:error, {:jobs, {:invalid, "schedule"}}}
    end
  end

  defp end_at(%{"end_at" => nil} = fields), do: {:ok, fields}

  defp end_at(%{"end_at" => text} = fields) do
    case DateTime.from_iso8601(text) do
      {:ok, instant, _offset} -> {:ok, %{fields | "end_at" => DateTime.to_iso8601(instant)}}
      _error -> {:error, {:jobs, {:invalid, "end_at"}}}
    end
  end

  @deliveries ~w(owner_inbox)

  defp delivery(nil), do: :ok

  defp delivery(value),
    do: if(value in @deliveries, do: :ok, else: {:error, {:jobs, {:invalid, "delivery"}}})

  defp owner(nil), do: :ok

  defp owner(identity),
    do: if(Participant.valid?(identity), do: :ok, else: {:error, {:jobs, {:invalid, "owner"}}})
end
