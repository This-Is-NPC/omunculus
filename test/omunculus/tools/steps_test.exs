defmodule Omunculus.Tools.StepsTest do
  use ExUnit.Case, async: true

  alias Omunculus.Fixtures
  alias Omunculus.Tools.Steps

  test "names each step an agent's tools chain that it lacks, groups expanded" do
    config =
      Fixtures.config("""
      [agents.lead]
      depth = 0
      text = "lead"
      tools = ["work", "end"]

      [agents.whole]
      depth = 0
      text = "whole"
      tools = ["work", "comment", "delegate", "end"]
      """)

    assert Steps.missing(config, ["lead", "whole"]) == [
             "lead: work runs comment, which lead lacks",
             "lead: work runs delegate, which lead lacks"
           ]
  end
end
