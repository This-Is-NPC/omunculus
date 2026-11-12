defmodule Omunculus.Tools.Report do
  @moduledoc """
  The report that ends a run, one shape for every tool that takes one:
  an object of the fields `Omunculus.Config.report_fields/0` names, each
  a non-empty string, at least one given and the ones `[policy]
  report_required` lists all given. `fetch/2` checks it and renders it as
  the comment the next run reads, one `**field:** text` line per field.
  A tool manifest takes the schema with `"report" = {"$ref" = "report"}`.
  """

  alias Omunculus.Config

  @descriptions %{
    "done" => "What was achieved.",
    "decided" => "Choices made and why.",
    "pending" => "What is left.",
    "files" => "Files and artifacts touched.",
    "verify" => "How to check the result."
  }

  @doc "The JSON schema of a report."
  @spec schema() :: map
  def schema do
    %{
      "type" => "object",
      "description" => "The report the next run starts from.",
      "properties" =>
        Map.new(
          Config.report_fields(),
          &{&1, %{"type" => "string", "description" => @descriptions[&1]}}
        )
    }
  end

  @doc "The report in `args`, checked against the `required` fields and rendered."
  @spec fetch(map, [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def fetch(args, required) do
    with {:ok, report} <- object(args["report"]),
         :ok <- known(report),
         fields = Enum.filter(Config.report_fields(), &present?(report, &1)),
         :ok <- given(fields, report, required) do
      {:ok, Enum.map_join(fields, "\n", &"**#{&1}:** #{report[&1]}")}
    end
  end

  defp object(%{} = report), do: {:ok, report}

  defp object(report) when is_binary(report) do
    case Jason.decode(report) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _ -> {:error, "report must be an object"}
    end
  end

  defp object(nil), do: {:error, "report required"}
  defp object(_report), do: {:error, "report must be an object"}

  defp known(report) do
    case Enum.find(Map.keys(report), &(&1 not in Config.report_fields())) do
      nil ->
        :ok

      key ->
        {:error,
         "report has no field #{key}; its fields are #{Enum.join(Config.report_fields(), ", ")}"}
    end
  end

  defp given([], _report, _required), do: {:error, "report needs at least one field"}

  defp given(_fields, report, required) do
    case Enum.find(required, &(not present?(report, &1))) do
      nil -> :ok
      field -> {:error, "report.#{field} required"}
    end
  end

  defp present?(report, field), do: is_binary(report[field]) and report[field] != ""
end
