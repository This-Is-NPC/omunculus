defmodule Omunculus.Tools.ProposePack do
  @moduledoc """
  Builtin `propose_pack` tool: loads the config `config_path` would make
  once the pack at `path`, relative to the workspace, is imported with
  `models`, `auth` and `depth` (`Omunculus.Config.try_pack/2`) and, when it
  loads, emits a request, on the route `Omunculus.RequestRoutes.owner/0` names, whose
  `apply` option calls `pack` with that
  import, and whose `deny` calls nothing; its reason gives the agent's
  `reason`, each of the pack's agents at the depth and on the model it
  would run, and what the pack's `environment/` holds, which the person
  runs. An import that does not load fails here, with why, and so does one
  whose agents lack a step their tools chain (`Omunculus.Tools.Steps`). Its manifest's
  `then` appends `end`.
  """

  alias Omunculus.{CLI, Config, RequestRoutes}
  alias Omunculus.Config.Packs
  alias Omunculus.Tools.{Args, Out, Steps}

  @spec run(map) :: map
  def run(%{args: args, config_path: path, roots: roots}) when is_binary(path) do
    dir = Path.expand(args["path"] || "", List.first(roots) || Path.dirname(path))

    with nil <- Args.missing(args, ~w(path reason)),
         true <- is_map(args["models"]) || "models required: each role and the model it runs on",
         {:ok, pack} <- Packs.read(dir),
         entry = entry(dir, args),
         {:ok, config} <- Config.try_pack(path, entry),
         [] <- Steps.missing(config, Map.keys(Map.get(pack, "agents", %{}))) do
      Out.ok("", [%{"type" => "request", "body" => request(args, dir, pack, entry, config)}])
    else
      {:error, {:packs, {_pack, :requires, _lacked}} = reason} ->
        Out.fail(CLI.format_error(reason))

      {:error, reason} ->
        Out.fail("the config would not load with it: #{inspect(reason)}")

      [_ | _] = missing ->
        Out.fail("its agents would be refused:\n" <> Enum.join(missing, "\n"))

      message ->
        Out.fail(message)
    end
  end

  def run(_input), do: Out.fail("config_path required")

  defp entry(dir, args) do
    %{"path" => dir, "models" => args["models"] || %{}, "auth" => args["auth"] || %{}}
    |> then(&if((args["depth"] || 0) > 0, do: Map.put(&1, "depth", args["depth"]), else: &1))
  end

  defp request(args, dir, pack, entry, config) do
    agents =
      for name <- pack |> Map.get("agents", %{}) |> Map.keys() |> Enum.sort(),
          agent = config.agents[name],
          do: "- #{name}: depth #{agent.depth}, model #{agent.model}"

    %{
      "to" => RequestRoutes.owner(),
      "reason" =>
        Enum.join(
          [
            args["reason"],
            "Import #{pack["pack"]["name"]} from #{dir}, its agents as they would run:\n" <>
              Enum.join(agents, "\n")
          ] ++ Omunculus.Tools.Pack.environment(dir),
          "\n\n"
        ),
      "options" => %{
        "apply" => [%{"name" => "pack", "args" => pack_args(entry)}],
        "deny" => []
      }
    }
  end

  defp pack_args(entry) do
    pairs = &Enum.map_join(&1, ",", fn {name, value} -> "#{name}=#{value}" end)

    %{
      "path" => entry["path"],
      "models" => pairs.(entry["models"]),
      "auth" => pairs.(entry["auth"])
    }
    |> then(&if(entry["depth"], do: Map.put(&1, "depth", to_string(entry["depth"])), else: &1))
  end
end
