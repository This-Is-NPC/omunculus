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

  test "a generalist above a required workflow does not hold the root" do
    config =
      Fixtures.config("""
      [agents.sales]
      depth = 0
      text = "sales"
      tools = ["work", "end"]

      [agents.seller]
      depth = 1
      text = "seller"
      workflow_only = true
      tools = ["work", "end"]

      [agents.administrator]
      depth = 2
      text = "administrator"
      tools = ["work", "delegate", "end"]

      [workflows.sale]
      steps = [{ name = "qualify", agent = "seller" }]

      [workflows.page]
      steps = [{ name = "build", agent = "seller" }]

      [policy.depth.1]
      workflows = ["sale"]

      [policy.depth.3]
      workflows = ["page"]
      """)

    assert Steps.missing(config, ["sales", "seller", "administrator"]) == [
             "administrator: work runs comment, which administrator lacks",
             "seller: work runs comment, which seller lacks",
             "seller: work runs delegate, which seller lacks"
           ]
  end
end
