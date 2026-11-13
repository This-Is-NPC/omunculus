defmodule Omunculus.Tools.ProposeJob do
  @moduledoc """
  Builtin `propose_job` tool: checks the job the args describe against the
  config and the jobs the project holds (`Omunculus.Jobs.Fields`) and
  emits a request, to whoever gave the agent its work, whose `approve`
  option calls `jobs create` with those args, whose `edit` option calls
  nothing and takes the person's change in its reply, and whose `deny` calls
  nothing. The request's reason gives the agent's `reason`, the runs it
  cites, and the job in words with its next fires. A job created by an
  approval is owned by `owner`, else by whoever approves it. Where `[jobs]
  agent_may_create` is true the job is created at once, owned by the agent,
  and nothing is asked.

  A job that is not valid fails here, with why, and so does a name taken,
  a project already holding `[jobs] max_jobs`, a run cited that is not among
  the project's recent runs and a proposal the person already answered
  without approving it. Whether the call came from a run that a job's fire
  opened is checked when the job is created (`Omunculus.Jobs.write/3`).
  """

  alias Omunculus.{Config, Errors}
  alias Omunculus.Jobs.{Fields, Summary}
  alias Omunculus.Tools.{Args, Cites, Out}

  @spec run(map) :: map
  def run(%{args: args, config_path: path} = input) when is_binary(path) do
    view = Map.get(input, :view) || %{}

    with nil <- Args.missing(args, ~w(name reason schedule timezone)),
         {:ok, config} <- Config.load(path),
         :ok <- enabled(config),
         {:ok, cited} <- Cites.check(args["runs"], view["recent"] || []),
         :ok <- Fields.name(args["name"]),
         {:ok, input} <- Fields.input(args, config),
         {:ok, fields} <- Fields.check(Map.merge(Fields.blank(), input), config),
         :ok <- free(args["name"], view["jobs"] || [], config),
         create = create_args(args),
         :ok <- not_refused(view["answered"] || [], create) do
      if config.jobs.agent_may_create,
        do: created(create),
        else: asked(args, fields, create, cited)
    else
      {:error, {:jobs, _reason} = reason} -> Out.fail(Errors.format(reason))
      {:error, reason} -> Out.fail("the config would not load: #{inspect(reason)}")
      message -> Out.fail(message)
    end
  end

  def run(_input), do: Out.fail("config_path required")

  defp enabled(%{jobs: nil}), do: "omunculus.toml has no [jobs] table, so the project has no jobs"
  defp enabled(_config), do: :ok

  defp free(name, jobs, config) do
    cond do
      Enum.any?(jobs, &(&1["name"] == name)) -> {:error, {:jobs, {:name_taken, name}}}
      length(jobs) >= config.jobs.max_jobs -> {:error, {:jobs, {:too_many, config.jobs.max_jobs}}}
      true -> :ok
    end
  end

  # The args `jobs create` takes, as the agent gave them.
  defp create_args(args) do
    args
    |> Map.take(["name" | Fields.keys()])
    |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.put("action", "create")
  end

  # A proposal that comes to what the person answered without approving.
  defp not_refused(answered, create) do
    refused =
      Enum.find(answered, fn request ->
        request.answer != "approve" and proposes?(request, create)
      end)

    case refused do
      nil -> :ok
      request -> "the person already answered this job without approving it: #{request.reply}"
    end
  end

  defp proposes?(request, create) do
    case request.options |> Jason.decode!() |> Map.get("approve") do
      [%{"name" => "jobs", "args" => args}] -> args == create
      _other -> false
    end
  end

  defp created(create) do
    body = create |> Map.delete("action") |> Map.put("op", "create")
    Out.ok("job #{create["name"]} created", [%{"type" => "job", "body" => body}])
  end

  defp asked(args, fields, create, cited) do
    lines = Summary.lines(fields) ++ owner_line(fields)

    reason =
      Enum.join(
        [
          args["reason"],
          Cites.line(cited),
          "job #{args["name"]} as it would run:\n" <> Enum.join(lines, "\n"),
          "approve creates it, edit sends back what to change, deny drops it"
        ],
        "\n\n"
      )

    Out.ok("", [
      %{
        "type" => "request",
        "body" => %{
          "reason" => reason,
          "options" => %{
            "approve" => [%{"name" => "jobs", "args" => create}],
            "edit" => [],
            "deny" => []
          }
        }
      }
    ])
    |> Map.put("chain", [%{"name" => "end", "args" => %{}}])
  end

  defp owner_line(%{"owner" => nil}), do: ["runs as: whoever approves it"]
  defp owner_line(_fields), do: []
end
