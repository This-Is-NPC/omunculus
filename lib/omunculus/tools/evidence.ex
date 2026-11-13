defmodule Omunculus.Tools.Evidence do
  @moduledoc """
  The evidence a `propose_config` proposal may carry: the `metric` the
  change should move, its value `before` and the value `expected` after, and
  a `workflow` whose BPMN pair is attached — as-is, mined from the log, and
  to-be, the workflow as the config would declare it once the change is
  applied (`Omunculus.Process.Bpmn`). Neither is drawn by the model. The
  pair is written as artifacts of the conversation, `<workflow>-as-is.bpmn`
  and `<workflow>-to-be.bpmn`, a version unchanged since the last left as
  it is; the request names them. `last` limits the log to its last
  conversations, as for `process`.
  """

  alias Omunculus.{Artifacts, Config}
  alias Omunculus.Process.{Bpmn, Log}

  @media_type "application/bpmn+xml"
  @kind "bpmn"

  @spec build(term, Config.t(), map) ::
          {:ok, %{lines: [String.t()], emit: [map]}} | {:error, String.t()}
  def build(nil, _config, _view), do: {:ok, %{lines: [], emit: []}}

  def build(%{} = evidence, config, view) do
    with {:ok, metric, before, expected} <- measure(evidence),
         {:ok, workflow} <- workflow(evidence, config),
         {:ok, as_is} <- as_is(Log.build(view["log"]), workflow) do
      versions = view["artifacts"] || []

      documents = [
        {"#{workflow}-as-is.#{@kind}", "as-is, mined from the log", as_is},
        {"#{workflow}-to-be.#{@kind}", "to-be, as the config would declare it",
         Bpmn.to_be(workflow, config.workflows[workflow], config.agents)}
      ]

      with {:ok, written} <- write(documents, config, versions) do
        {:ok,
         %{
           lines: [
             "Evidence: the metric is #{metric}, #{before} now, expected #{expected} after this change.",
             "BPMN of #{workflow}:\n" <> Enum.map_join(written, "\n", &"- #{&1.label}")
           ],
           emit: for(%{emit: emit} <- written, emit, do: emit)
         }}
      end
    end
  end

  def build(_evidence, _config, _view),
    do: {:error, "evidence is a table: metric, before, expected, workflow"}

  defp measure(evidence) do
    case Enum.map(~w(metric before expected), &Map.get(evidence, &1)) do
      [metric, before, expected]
      when is_binary(metric) and metric != "" and not is_nil(before) and not is_nil(expected) ->
        {:ok, metric, before, expected}

      _other ->
        {:error, "evidence needs a metric (text) and its before and expected values"}
    end
  end

  defp workflow(%{"workflow" => name}, config) when is_binary(name) do
    if Map.has_key?(config.workflows, name),
      do: {:ok, name},
      else: {:error, "evidence names workflow #{name}, which the config would not have"}
  end

  defp workflow(_evidence, _config),
    do: {:error, "evidence needs the workflow its BPMN pair shows"}

  defp as_is(log, workflow) do
    case Log.traces(log, workflow) do
      [] ->
        {:error, "no work went through #{workflow} in the log, so there is no as-is to attach"}

      traces ->
        {:ok, Bpmn.as_is(workflow, traces)}
    end
  end

  defp write(documents, config, versions) do
    Enum.reduce_while(documents, {:ok, []}, fn {name, label, content}, {:ok, acc} ->
      case Artifacts.check(
             config.store,
             versions,
             name,
             @kind,
             @media_type,
             byte_size(content),
             nil
           ) do
        :ok ->
          {:cont, {:ok, acc ++ [artifact(name, label, content, versions)]}}

        {:error, reason} ->
          {:halt, {:error, "the BPMN could not be kept as #{name}: #{inspect(reason)}"}}
      end
    end)
  end

  defp artifact(name, label, content, versions) do
    case Artifacts.unchanged(versions, name, @media_type, content) do
      %{"version" => version} ->
        %{label: "#{name} version #{version}: #{label}", emit: nil}

      nil ->
        body =
          %{"name" => name, "kind" => @kind, "media_type" => @media_type}
          |> Map.merge(Artifacts.payload(content))

        %{
          label: "#{name} version #{Artifacts.next(name, versions)}: #{label}",
          emit: %{"type" => "artifact", "body" => body}
        }
    end
  end
end
