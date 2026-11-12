defmodule Omunculus.DeliverGateTest do
  @moduledoc """
  The dream team's `deliver` gate on the pilot's plan: a `## Release` item is
  covered by a done work of the workflow release, not by a page.
  """
  use ExUnit.Case, async: true

  @run Path.expand("../../packs/dream-team/tools/deliver/run", __DIR__)
  @plan "# Plan\n\n## base\n\n## page: home\n\n## Release\n"

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "docs"))
    File.write!(Path.join([dir, "docs", "plan.md"]), @plan)
    {:ok, root: dir}
  end

  defp child(title, workflow, state \\ "done"),
    do: %{"title" => title, "workflow" => workflow, "state" => state}

  defp deliver(root, children) do
    input =
      Jason.encode!(%{
        args: %{report: "done"},
        roots: [root],
        view: %{work: %{goal: "Build the bakery"}, children: children}
      })

    {out, 0} =
      System.cmd("sh", ["-c", ~S(printf '%s' "$INPUT" | exec "$0"), @run],
        env: [{"INPUT", input}]
      )

    Jason.decode!(out)
  end

  defp items, do: [child("base", "page"), child("page: home", "page")]

  test "a done release work covers the ## Release item", %{root: root} do
    assert %{"ok" => true} = deliver(root, items() ++ [child("release", "release")])
  end

  test "without a done release work the gate asks for it", %{root: root} do
    assert %{"ok" => false, "output" => out} =
             deliver(root, items() ++ [child("release", "release", "running")])

    assert out =~ "hand down the release"
  end

  test "a missing page item is still refused", %{root: root} do
    assert %{"ok" => false, "output" => out} =
             deliver(root, [child("base", "page"), child("release", "release")])

    assert out =~ "page: home"
    refute out =~ "Release"
  end
end
