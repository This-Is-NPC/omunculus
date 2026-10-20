defmodule EquivalentExchange.Requests do
  @moduledoc "Answers eval requests through their linked named origins without changing permission targets."
  alias EquivalentExchange.Task

  def answer(task, groups, request, project, reply) do
    case choose(task, groups, request, project) do
      nil ->
        if requirements(request) == [] and question?(request) do
          case reply.(request.reason) do
            {:ok, :nothing} -> {:ok, nil}
            {:ok, text} -> {:ok, %{"body" => text}}
            {:error, _reason} = error -> error
          end
        else
          {:ok, nil}
        end

      answer ->
        {:ok, answer}
    end
  end

  # What the person answers in words: a question, or a decision `leaf`
  # picks no option of, as a person given choices may still write. The
  # harness's retry is not theirs to answer.
  defp question?(request) do
    origins = Map.get(request, :origins, %{})

    if map_size(origins) == 0,
      do: not Map.has_key?(Jason.decode!(request.options), "retry"),
      else: Enum.any?(origins, fn {_part, origin} -> question?(origin) end)
  end

  def choose(task, groups, request, project) do
    origins = Map.get(request, :origins, %{})

    if map_size(origins) == 0 do
      case leaf(task, groups, request, project) do
        {nil, nil} -> nil
        {option, body} -> %{"option" => option, "body" => body}
      end
    else
      parts =
        for {part, origin} <- origins,
            origin.status in ~w(pending escalated),
            answer = choose(task, groups, origin, project),
            not is_nil(answer),
            into: %{},
            do: {part, answer}

      if map_size(parts) > 0,
        do: %{"body" => "Answers to the linked requests.", "parts" => parts},
        else: nil
    end
  end

  def arguments(config_path, request_id, answer) do
    ["--config", config_path, "reply", "--request_id", request_id, "--body", answer["body"]] ++
      if(answer["option"], do: ["--option", answer["option"]], else: []) ++
      if answer["parts"], do: ["--parts", Jason.encode!(answer["parts"])], else: []
  end

  def answers(request, answer) do
    [
      %{request: request.id, option: answer["option"], body: answer["body"]}
      | Enum.flat_map(Map.get(answer, "parts", %{}), fn {part, value} ->
          answers(request.origins[part], value)
        end)
    ]
  end

  def requirements(request) do
    Enum.uniq(
      requested(Jason.decode!(request.options)) ++
        Enum.flat_map(Map.get(request, :origins, %{}), fn {_part, origin} ->
          requirements(origin)
        end)
    )
  end

  # A decision — a request granting nothing — gets the option the task's
  # `[human] decision` names. Grant when the task grants everything the
  # request asks, by the name or by a group that holds it; deny otherwise,
  # saying what it would not grant and what it would, as a person does. A grant is temporary when the request
  # offers it, else for the asking agent (a request made without a work
  # offers no temporary one). A request without grant and deny (retry or
  # cancel) is left waiting.
  defp leaf(task, groups, request, project) do
    options = Jason.decode!(request.options)
    names = asks(options, project)

    {granted, denied} =
      Enum.split_with(names, fn name ->
        Enum.any?([name | groups_of(groups, name)], &(Task.answer(task, &1) == "grant"))
      end)

    grant = Enum.find(["grant", "grant_agent"], &Map.has_key?(options, &1))
    decision = task.human["decision"]

    cond do
      names == [] and Map.has_key?(options, decision) ->
        {decision, "Decided: #{decision}."}

      names != [] and denied == [] and grant != nil ->
        {grant, "Granted: #{Enum.join(granted, ", ")}."}

      Map.has_key?(options, "deny") ->
        {"deny", refusal(denied, granted)}

      true ->
        {nil, nil}
    end
  end

  defp refusal([], _granted), do: "Not granted."
  defp refusal(denied, []), do: "Not granted: #{Enum.join(denied, ", ")}."

  defp refusal(denied, granted),
    do:
      "Not granted: #{Enum.join(denied, ", ")}. I would grant #{Enum.join(granted, ", ")}: ask again without the rest."

  defp groups_of(groups, name), do: for({group, members} <- groups, name in members, do: group)

  def requested(options) do
    for {_option, calls} <- options,
        %{"name" => "grant", "args" => %{"name" => _name} = args} <- calls,
        uniq: true,
        do: Map.take(args, ~w(kind name))
  end

  def asks(options, project),
    do: options |> requested() |> Enum.map(&subject(&1, project)) |> Enum.uniq()

  # What a grant gives, as the task names it: writing a path or directory
  # inside the workspace is sandbox.write; anything else is its name.
  defp subject(%{"kind" => kind, "name" => name}, project) when kind in ~w(path directory) do
    workspace = Path.join(project, "workspace")
    path = Path.expand(name, workspace)

    if path == workspace or String.starts_with?(path, workspace <> "/"),
      do: "sandbox.write",
      else: name
  end

  defp subject(%{"name" => name}, _project), do: name
end
