defmodule Omunculus.CLI.HelpTest do
  use ExUnit.Case, async: true

  alias Omunculus.CLI.Help

  test "root short help has usage and commands" do
    assert {:ok, text} = Help.render("root", :short)
    assert text =~ "Usage: omunculus"
    assert text =~ "Commands:"
    assert text =~ "run"
    refute text =~ "Exit codes:"
  end

  test "root long help includes examples and exit codes" do
    assert {:ok, text} = Help.render("root", :long)
    assert text =~ "Examples:"
    assert text =~ "Exit codes:"
    assert text =~ "does not speak Anthropic Messages"
  end

  test "run help lists required args and env-backed flags" do
    assert {:ok, text} = Help.render("run", :long)
    assert text =~ "<dir>"
    assert text =~ "<instruction>..."
    assert text =~ "--preset"
    assert text =~ "[env: OMUNCULUS_MODEL]"
    assert text =~ "[default: 32]"
  end
end
