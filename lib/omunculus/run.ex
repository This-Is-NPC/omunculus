defmodule Omunculus.Run do
  @moduledoc """
  Opens and drives one run of the depth-0 agent, start to end (spec §3.2,
  §3.3): reads the project config now, assembles the prompt from the
  agent text, the message of this opening, the work's title and last
  comment when the run is on a work, and the effective tools' cards, lets
  the model call tools through the harness, and closes the run when the
  model is done. The assembled is rebuilt from the store views on every
  opening — it never reuses a previous assembled nor the event log.
  Nobody waits afterwards.
  """

  alias Omunculus.{Config, Harness, Project, Store}
  alias Omunculus.Tool.{Catalog, Manifest}

  @spec open(
          Project.t(),
          %{prompt_id: String.t(), work_id: String.t() | nil},
          (String.t(), fun -> {:ok, String.t()} | {:error, term})
        ) :: {:ok, map} | {:error, term}
  def open(project, %{prompt_id: message_prompt_id, work_id: work_id}, model) do
    with {:ok, config} <- Config.load(project.dir),
         {:ok, {name, agent}} <- Config.agent_at_depth(config, 0),
         {:ok, message} <- fetch_prompt(project.conn, message_prompt_id),
         {:ok, work} <- fetch_work(project.conn, work_id),
         {:ok, comment} <- fetch_last_comment(project.conn, work_id),
         {names, catalog} = effective_tools(project.dir, agent),
         assembled = assemble(agent, message, work, comment, names, catalog),
         {:ok, run} <-
           Store.open_run(project.conn, %{
             prompt_id: message_prompt_id,
             agent: name,
             depth: 0,
             tools: names,
             assembled: assembled,
             work_id: work_id,
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

  defp fetch_work(_conn, nil), do: {:ok, nil}

  defp fetch_work(conn, work_id) do
    case Store.view(conn, "work", work_id) do
      {:ok, nil} -> {:error, {:no_work, work_id}}
      {:ok, work} -> {:ok, work}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_last_comment(_conn, nil), do: {:ok, nil}

  defp fetch_last_comment(conn, work_id) do
    case Store.view(conn, "comments.work", work_id) do
      {:ok, comments} -> {:ok, List.last(comments)}
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

  defp assemble(agent, message, work, comment, names, catalog) do
    cards = Enum.map(names, &Manifest.card(Map.fetch!(catalog, &1)))

    sections =
      [String.trim(agent.text)] ++
        message_section(message) ++
        work_section(work) ++
        comment_section(comment) ++
        ["## Tools\nAs tools estão em `tools.*`.\n" <> Enum.join(cards, "\n")]

    Enum.join(sections, "\n\n")
  end

  defp message_section(message), do: ["## Message\n#{message.body}"]

  defp work_section(nil), do: []
  defp work_section(work), do: ["## Work\n#{work.title}"]

  defp comment_section(nil), do: []
  defp comment_section(comment), do: ["## Last comment\n#{comment.body}"]

  defp build_call(project, run, names, model) do
    allowed = MapSet.new(names)

    fn name, args ->
      if MapSet.member?(allowed, name) do
        ctx = %{trigger: "model", run_id: run.id, author: "agent", agent: run.agent, model: model}

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
