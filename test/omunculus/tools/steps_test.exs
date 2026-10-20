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

  test "asks only the steps of then of an agent that never holds a work" do
    config =
      Fixtures.config("""
      [agents.front]
      depth = 0
      text = "front"
      tools = ["work", "end"]

      [agents.clerk]
      depth = 0
      text = "clerk"
      workflow_only = true
      tools = ["work", "end"]

      [workflows.sale]
      steps = [{ name = "qualify", agent = "clerk" }]

      [policy.depth.0]
      workflows = ["sale"]
      """)

    assert Steps.missing(config, ["clerk", "front"]) == [
             "clerk: work runs comment, which clerk lacks",
             "clerk: work runs delegate, which clerk lacks"
           ]
  end
end
