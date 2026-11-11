defmodule Omunculus.Interceptors do
  @moduledoc """
  The project's `[[interceptors]]`: rules that turn an action of an agent
  into a review request to the rule's accounts. A rule names an `action`
  (`ask`, `comment`, `attach`, `grant` or `tool`, with `tool` naming the
  tool) and optionally narrows it to a target `to` (`"requester"`, an
  `[accounts]` name or an agent), an `agent`, a `workflow` and its `stage`.
  `accounts` are the reviewers, in order: `[accounts]` names or agents.
  """

  alias Omunculus.{Accounts, Participant}

  @actions ~w(ask comment attach grant tool)
  @keys ~w(action tool to agent workflow stage accounts)

  @type rule :: %{
          action: String.t(),
          tool: String.t() | nil,
          to: String.t() | nil,
          agent: String.t() | nil,
          workflow: String.t() | nil,
          stage: String.t() | nil,
          accounts: [String.t()]
        }

  @doc "The action kinds a rule names."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @spec parse(term, map, map, map) :: {:ok, [rule]} | {:error, {:interceptors, term}}
  def parse(nil, _agents, _accounts, _workflows), do: {:ok, []}

  def parse(list, agents, accounts, workflows) when is_list(list) do
    names = Enum.sort(Map.keys(accounts) ++ Map.keys(agents))

    list
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {raw, position}, {:ok, rules} ->
      case rule(raw, agents, names, workflows) do
        {:ok, rule} -> {:cont, {:ok, rules ++ [rule]}}
        {:error, reason} -> {:halt, {:error, {:interceptors, {position, reason}}}}
      end
    end)
  end

  def parse(_list, _agents, _accounts, _workflows), do: {:error, {:interceptors, :invalid}}

  defp rule(raw, agents, names, workflows) when is_map(raw) do
    with :ok <- known_keys(raw),
         {:ok, action} <- action(raw),
         {:ok, tool} <- tool(action, raw),
         {:ok, to} <- to(action, raw, names),
         {:ok, agent} <- optional(raw, "agent", fn name -> Map.has_key?(agents, name) end),
         {:ok, workflow} <- optional(raw, "workflow", &Map.has_key?(workflows, &1)),
         {:ok, stage} <- stage(raw, workflow, workflows),
         {:ok, reviewers} <- reviewers(raw, names) do
      {:ok,
       %{
         action: action,
         tool: tool,
         to: to,
         agent: agent,
         workflow: workflow,
         stage: stage,
         accounts: reviewers
       }}
    end
  end

  defp rule(_raw, _agents, _names, _workflows), do: {:error, :not_a_table}

  defp known_keys(raw) do
    case Map.keys(raw) -- @keys do
      [] -> :ok
      [key | _] -> {:error, {:unknown_key, key}}
    end
  end

  defp action(%{"action" => action}) when action in @actions, do: {:ok, action}
  defp action(_raw), do: {:error, :action}

  defp tool("tool", %{"tool" => tool}) when is_binary(tool) and tool != "", do: {:ok, tool}
  defp tool("tool", _raw), do: {:error, :tool_required}
  defp tool(_action, %{"tool" => _tool}), do: {:error, :tool_only}
  defp tool(_action, _raw), do: {:ok, nil}

  defp to("tool", %{"to" => _to}, _names), do: {:error, :tool_has_no_target}
  defp to(_action, %{"to" => "requester"}, _names), do: {:ok, "requester"}

  defp to(_action, %{"to" => name}, names) do
    if name in names, do: {:ok, name}, else: {:error, {:unknown_name, "to", name, names}}
  end

  defp to(_action, _raw, _names), do: {:ok, nil}

  defp optional(raw, key, known?) do
    case Map.fetch(raw, key) do
      :error ->
        {:ok, nil}

      {:ok, name} when is_binary(name) ->
        if known?.(name), do: {:ok, name}, else: {:error, {:unknown, key, name}}

      {:ok, _other} ->
        {:error, {:invalid, key}}
    end
  end

  defp stage(%{"stage" => _stage}, nil, _workflows), do: {:error, :stage_needs_workflow}

  defp stage(%{"stage" => stage}, workflow, workflows) when is_binary(stage) do
    if Enum.any?(workflows[workflow], &(&1.name == stage)),
      do: {:ok, stage},
      else: {:error, {:unknown_stage, workflow, stage}}
  end

  defp stage(%{"stage" => _stage}, _workflow, _workflows), do: {:error, {:invalid, "stage"}}
  defp stage(_raw, _workflow, _workflows), do: {:ok, nil}

  defp reviewers(%{"accounts" => [_ | _] = list}, names) do
    case Enum.find(list, &(not (is_binary(&1) and &1 in names))) do
      nil -> {:ok, list}
      other -> {:error, {:unknown_name, "accounts", other, names}}
    end
  end

  defp reviewers(_raw, _names), do: {:error, :accounts}

  @doc "Whether any rule names `action`."
  @spec any?(Omunculus.Config.t(), String.t()) :: boolean
  def any?(config, action), do: Enum.any?(config.interceptors, &(&1.action == action))

  @doc """
  The first rule not in `passed` (indexes already released) that holds an
  `action` of `agent`, with the reviewers other than the agent itself: a
  rule left with none does not apply. `facts` are `:tool`, `:workflow`, `:stage`, `:target`
  (the identity the action reaches, or nil) and `:requester` (the
  conversation's requester identity, or nil). Returns `{index, rule}`.
  """
  @spec find(Omunculus.Config.t(), String.t(), String.t() | nil, map, [non_neg_integer]) ::
          {non_neg_integer, rule} | nil
  def find(config, action, agent, facts, passed) do
    config.interceptors
    |> Enum.with_index()
    |> Enum.map(fn {rule, index} -> {without(config, rule, agent), index} end)
    |> Enum.find(fn {rule, index} ->
      rule.accounts != [] and index not in passed and rule.action == action and
        (is_nil(rule.tool) or rule.tool == facts[:tool]) and
        (is_nil(rule.agent) or rule.agent == agent) and
        (is_nil(rule.workflow) or rule.workflow == facts[:workflow]) and
        (is_nil(rule.stage) or rule.stage == facts[:stage]) and
        target?(config, rule.to, facts)
    end)
    |> case do
      nil -> nil
      {rule, index} -> {index, rule}
    end
  end

  defp without(config, rule, agent) do
    mine = {:ok, Participant.agent(agent)}
    %{rule | accounts: Enum.reject(rule.accounts, &(Accounts.identity(config, &1) == mine))}
  end

  defp target?(_config, nil, _facts), do: true
  defp target?(_config, _to, %{target: nil}), do: false
  defp target?(_config, "requester", facts), do: facts.target == facts[:requester]

  defp target?(config, name, facts),
    do: Accounts.identity(config, name) == {:ok, facts.target}
end
