defmodule Omunculus.Run do
  @moduledoc """
  Opens and drives one run of the depth-0 agent, start to end (spec §3.2,
  §3.3): reads the project config now, assembles the prompt from the
  agent text, the message and the effective tools' cards, lets the model
  call tools through the harness, and closes the run when the model is
  done. Nobody waits afterwards.
  """

  alias Omunculus.{Config, Harness, Project, Store}
  alias Omunculus.Tool.{Catalog, Manifest}

  @spec open(Project.t(), String.t(), (String.t(), fun -> {:ok, String.t()} | {:error, term})) ::
          {:ok, map} | {:error, term}
  def open(project, message_prompt_id, model) do
    with {:ok, config} <- Config.load(project.dir),
         {:ok, {name, agent}} <- Config.agent_at_depth(config, 0),
         {:ok, message} <- fetch_prompt(project.conn, message_prompt_id),
         {names, catalog} = effective_tools(project.dir, agent),
         assembled = assemble(agent, message, names, catalog),
         {:ok, run} <-
           Store.open_run(project.conn, %{
             prompt_id: message_prompt_id,
             agent: name,
             depth: 0,
             tools: names,
             assembled: assembled,
             work_id: nil,
             via: nil,
             request_id: nil
           }),
         call = build_call(project, run, names, model),
         {:ok, text} <- model.(assembled, call),
         {:ok, _event} <- Store.record_model(project.conn, run.id, text),
         {:ok, _event} <- Store.close_run(project.conn, run.id) do
      {:ok, run}
    end
  end

  defp fetch_prompt(conn, id) do
    case Store.view(conn, "prompt", id) do
      {:ok, nil} -> {:error, {:no_prompt, id}}
      {:ok, prompt} -> {:ok, prompt}
      {:error, _reason} = error -> error
    end
  end

  defp effective_tools(dir, agent) do
    catalog =
      dir
      |> Catalog.roots()
      |> Catalog.discover()
      |> Catalog.with_trigger("model")

    names =
      case agent.tools do
        list when is_list(list) -> Enum.filter(list, &Map.has_key?(catalog, &1))
        nil -> Map.keys(catalog)
      end

    {Enum.sort(names), catalog}
  end

  defp assemble(agent, message, names, catalog) do
    header = [
      String.trim(agent.text),
      "",
      "## Message",
      message.body,
      "",
      "## Tools",
      "As tools estão em `tools.*`."
    ]

    cards = Enum.map(names, &Manifest.card(Map.fetch!(catalog, &1)))

    Enum.join(header ++ cards, "\n")
  end

  defp build_call(project, run, names, model) do
    allowed = MapSet.new(names)

    fn name, args ->
      if MapSet.member?(allowed, name) do
        ctx = %{trigger: "model", run_id: run.id, work_id: nil, author: "agent", model: model}

        case Harness.dispatch(project, name, args, ctx) do
          {:ok, out} -> {:ok, out.output}
          {:error, _reason} = error -> error
        end
      else
        {:error, {:not_allowed, name}}
      end
    end
  end
end
