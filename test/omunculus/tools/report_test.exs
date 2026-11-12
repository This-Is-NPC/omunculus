defmodule Omunculus.Tools.ReportTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tools.Report

  test "renders the fields given, in order, one labelled line each" do
    report = %{"verify" => "run the tests", "done" => "fixed", "files" => "lib/a.ex"}

    assert Report.fetch(%{"report" => report}, []) ==
             {:ok, "**done:** fixed\n**files:** lib/a.ex\n**verify:** run the tests"}
  end

  test "accepts the JSON spelling of the object, as the command line gives it" do
    assert Report.fetch(%{"report" => ~s({"done":"fixed"})}, []) == {:ok, "**done:** fixed"}
  end

  test "refuses what is not an object, without a field, or with an unknown one" do
    assert Report.fetch(%{}, []) == {:error, "report required"}
    assert Report.fetch(%{"report" => "fixed"}, []) == {:error, "report must be an object"}
    assert Report.fetch(%{"report" => %{}}, []) == {:error, "report needs at least one field"}

    assert Report.fetch(%{"report" => %{"done" => ""}}, []) ==
             {:error, "report needs at least one field"}

    assert {:error, "report has no field extra" <> _} =
             Report.fetch(%{"report" => %{"done" => "x", "extra" => "y"}}, [])
  end

  test "refuses a report that lacks a field the policy requires" do
    report = %{"report" => %{"done" => "fixed"}}
    assert Report.fetch(report, ["done"]) == {:ok, "**done:** fixed"}
    assert Report.fetch(report, ["done", "pending"]) == {:error, "report.pending required"}
  end

  test "the one schema is what every ending tool's manifest takes" do
    catalog = Omunculus.Tool.Catalog.unconfigured()

    for name <- ~w(done work break wait request_access) do
      assert catalog[name].parameters["properties"]["report"] == Report.schema()
      assert Enum.any?(catalog[name].views, &(&1.source == "report_required"))
    end
  end
end
