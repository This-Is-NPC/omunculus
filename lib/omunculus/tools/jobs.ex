defmodule Omunculus.Tools.Jobs do
  @moduledoc """
  Builtin `jobs` tool, the command line's way to scheduled jobs
  (`Omunculus.Jobs`) and the call an approved proposal chains. `action` is

  - `list`, `show` and `history` (`name`), which read the `jobs` and
    `history` views: the jobs with their totals, one in full with its next
    fires, and the newest events of one; `preview` (`schedule`, `timezone`,
    `agent` or `workflow`), which reads the `preview` view: the next three
    fires and what a fire is estimated to cost;
  - `create` (`name` and the fields of `Omunculus.Jobs.Fields`),
    `edit` (`name` and the fields to change), `duplicate` (`name` and the
    new name `as`), `pause` and `resume` (`name`, optionally a `reason`),
    `archive`, `run` and `read` (`name`: the job's delivered thread is read), which emit one `job` action.

  The store applies and refuses them; this tool only shapes what it reads.
  """

  alias Omunculus.Jobs.{Fields, Summary}
  alias Omunculus.Tools.{Args, Out}

  @moves %{"pause" => "paused", "resume" => "active", "archive" => "archived"}
  @actions ~w(list show history preview create edit duplicate run read) ++ Map.keys(@moves)

  @spec run(map) :: map
  def run(%{args: args, view: view}) do
    case args["action"] do
      "list" -> list(view["jobs"] || [])
      "show" -> with_job(args, view, &show/1)
      "history" -> with_job(args, view, fn _job -> history(view["history"] || []) end)
      "preview" -> preview(view["preview"])
      action when action in @actions -> write(action, args)
      _other -> Out.fail("action is one of: #{Enum.join(@actions, ", ")}")
    end
  end

  defp write("create", args) do
    case Args.fetch(args, "name") do
      {:ok, name} ->
        body = args |> fields() |> Map.put("name", name) |> Args.put_present("state", args)
        emit("create", body, args, "created #{name}")

      {:error, message} ->
        Out.fail(message)
    end
  end

  defp write("duplicate", args) do
    case Args.missing(args, ~w(name as)) do
      nil ->
        body = %{"job" => args["name"], "name" => args["as"]}
        emit("duplicate", body, args, "copied #{args["name"]} to #{args["as"]}")

      message ->
        Out.fail(message)
    end
  end

  defp write("edit", args), do: on_job("change", args, fields(args), "changed")
  defp write("read", args), do: on_job("read", args, %{}, "marked read")
  defp write("run", args), do: on_job("run", args, %{}, "queued a run of")

  defp write(action, args) do
    body = %{"to" => Map.fetch!(@moves, action)} |> Args.put_present("reason", args)
    on_job("transition", args, body, "#{action}d")
  end

  defp on_job(op, args, body, said) do
    case Args.fetch(args, "name") do
      {:ok, name} -> emit(op, Map.put(body, "job", name), args, "#{said} #{name}")
      {:error, message} -> Out.fail(message)
    end
  end

  defp emit(op, body, args, said) do
    body =
      body
      |> Map.put("op", op)
      |> Args.put_present("channel", args)
      |> Args.put_present("request_id", args)

    Out.ok(said, [%{"type" => "job", "body" => body}])
  end

  defp fields(args), do: Map.take(args, Fields.keys())

  defp with_job(args, view, fun) do
    with {:ok, name} <- Args.fetch(args, "name"),
         job when not is_nil(job) <-
           Enum.find(view["jobs"] || [], &(&1["name"] == name or &1["id"] == name)) do
      fun.(job)
    else
      {:error, message} -> Out.fail(message)
      nil -> Out.fail("no job #{args["name"]}")
    end
  end

  defp preview(%{"error" => message}), do: Out.fail(message)

  defp preview(preview) do
    estimate =
      case preview["estimate_usd"] do
        nil -> "no estimate"
        usd -> "about $#{Float.round(usd * 1.0, 4)} each"
      end

    Out.ok(
      "next fires: #{Enum.join(preview["next"], ", ")}\ncost per fire: #{estimate} (#{preview["basis"]})"
    )
  end

  defp list([]), do: Out.ok("No jobs.")

  defp list(jobs) do
    Out.ok(
      Enum.map_join(jobs, "\n", fn job ->
        "- #{job["name"]} [#{job["state"]}] #{job["schedule"]} (#{job["timezone"]}); " <>
          "next #{job["next_fire"] || "none"}; fires #{job["fires"]["fires"]}, " <>
          "$#{Float.round(job["fires"]["usd"] * 1.0, 4)}"
      end)
    )
  end

  defp show(job) do
    totals = job["fires"]

    Out.ok(
      Enum.join(
        [
          "#{job["name"]} [#{job["state"]}], version #{job["version"]}, id #{job["id"]}"
          | Summary.lines(job)
        ] ++
          [
            "fires: #{totals["fires"]} finished, #{totals["succeeded"]} succeeded, #{totals["failed"]} failed, #{totals["skipped"]} skipped, #{totals["missed"]} missed; $#{Float.round(totals["usd"] * 1.0, 4)}",
            "last fire: #{last(job["last_fire"])}",
            "next fire: #{job["next_fire"] || "none"}"
          ],
        "\n"
      )
    )
  end

  defp last(nil), do: "none"
  defp last(fire), do: "#{fire["state"]} (scheduled #{fire["scheduled_for"]})"

  defp history([]), do: Out.ok("No events.")

  defp history(events) do
    Out.ok(
      Enum.map_join(events, "\n", fn event ->
        "#{event["at"]} #{event["op"]} #{detail(event)}"
      end)
    )
  end

  defp detail(%{"op" => "fire"} = event),
    do:
      "#{event["state"]} fire #{event["fire_id"]}" <>
        if(event["reason"], do: ": #{event["reason"]}", else: "")

  defp detail(%{"op" => "transition"} = event),
    do:
      "#{event["from"]} -> #{event["to"]}" <>
        if(event["reason"], do: ": #{event["reason"]}", else: "") <> by(event)

  defp detail(event), do: "version #{event["version"]}" <> by(event)

  defp by(%{"origin" => %{"author" => author, "channel" => channel}}),
    do: " by #{label(author)} via #{channel}"

  defp label(%{"kind" => "harness"}), do: "the harness"
  defp label(identity), do: Omunculus.Participant.label(identity)
end
