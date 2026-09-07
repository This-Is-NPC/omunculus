defmodule Omunculus.CLI.ParserTest do
  use ExUnit.Case, async: true

  alias Omunculus.CLI.Parser

  test "bare invocation requests short help" do
    assert {:ok, %{command: :help, target: "root", else_help: true, style: :short}} =
             Parser.parse([], %{})
  end

  test "-h is short help and --help is long help" do
    assert {:ok, %{command: :help, style: :short}} = Parser.parse(["-h"], %{})
    assert {:ok, %{command: :help, style: :long}} = Parser.parse(["--help"], %{})
  end

  test "-V prints version action" do
    assert {:ok, %{command: :version}} = Parser.parse(["-V"], %{})
    assert {:ok, %{command: :version}} = Parser.parse(["--version"], %{})
  end

  test "unknown long flag is an error" do
    assert {:error, {:unknown_flag, "--hekp"}} = Parser.parse(["--hekp"], %{})
  end

  test "run binds dir and a multi-word instruction" do
    assert {:ok, %{command: :run, args: %{dir: "./app", instruction: "add a README"}}} =
             Parser.parse(["run", "./app", "add", "a", "README"], %{})
  end

  test "default subcommand catches an unmatched first word" do
    assert {:ok, %{command: :run, args: %{dir: "./app", instruction: "fix it"}}} =
             Parser.parse(["./app", "fix", "it"], %{})
  end

  test "attached and detached flag values bind the same" do
    {:ok, a} = Parser.parse(["run", "./app", "x", "--preset=plan"], %{})
    {:ok, b} = Parser.parse(["run", "./app", "x", "--preset", "plan"], %{})
    assert a.flags["preset"] == "plan"
    assert b.flags["preset"] == "plan"
  end

  test "run and spike accept --profile" do
    {:ok, run} = Parser.parse(["run", "./app", "x", "--profile", "count"], %{})
    assert run.flags["profile"] == "count"

    {:ok, spike} = Parser.parse(["spike", "conte até 3", "--profile", "count"], %{})
    assert spike.flags["profile"] == "count"
  end

  test "run profile wins over preset when both are set" do
    {:ok, run} =
      Parser.parse(["run", "./app", "x", "--profile", "count", "--preset", "plan"], %{})

    assert run.flags["profile"] == "count"
    assert run.flags["preset"] == "plan"
  end

  test "tools delimiter splits one token into a list" do
    {:ok, parsed} = Parser.parse(["run", "./app", "x", "--tools", "read,grep,ls"], %{})
    assert parsed.flags["tools"] == ["read", "grep", "ls"]
  end

  test "run flags are accepted before the subcommand word" do
    {:ok, parsed} = Parser.parse(["--preset", "plan", "run", "./app", "x"], %{})
    assert parsed.command == :run
    assert parsed.flags["preset"] == "plan"
  end

  test "command line beats env, env beats default" do
    env = %{"OMUNCULUS_PRESET" => "plan", "OMUNCULUS_MAX_TURNS" => "8"}

    {:ok, from_env} = Parser.parse(["run", "./app", "x"], env)
    assert from_env.flags["preset"] == "plan"
    assert from_env.flags["max_turns"] == "8"

    {:ok, from_argv} =
      Parser.parse(["run", "./app", "x", "--preset", "coding", "--max-turns", "4"], env)

    assert from_argv.flags["preset"] == "coding"
    assert from_argv.flags["max_turns"] == "4"

    {:ok, from_default} = Parser.parse(["run", "./app", "x"], %{})
    assert from_default.flags["max_turns"] == "32"
    refute Map.has_key?(from_default.flags, "preset")
  end

  test "-- stops flag interpretation" do
    {:ok, parsed} = Parser.parse(["run", "./app", "--", "--not-a-flag"], %{})
    assert parsed.args.instruction == "--not-a-flag"
  end

  test "missing flag value is an error" do
    assert {:error, {:missing_flag_value, "--preset"}} =
             Parser.parse(["run", "./app", "x", "--preset"], %{})
  end

  test "help subcommand describes run" do
    assert {:ok, %{command: :help, target: "run", style: :long}} =
             Parser.parse(["help", "run"], %{})
  end

  test "monkey-job accepts an instruction with no tools" do
    assert {:ok, %{command: :"monkey-job", args: %{instruction: "count to 10"}} = parsed} =
             Parser.parse(["monkey-job", "count", "to", "10"], %{})

    refute Map.has_key?(parsed.flags, "tools")
  end

  test "monkey-job parses tools, delay, and increment" do
    assert {:ok, parsed} =
             Parser.parse(
               [
                 "monkey-job",
                 "count to 10",
                 "--tools",
                 "counter",
                 "--delay",
                 "500ms",
                 "--increment",
                 "1"
               ],
               %{}
             )

    assert parsed.flags["tools"] == ["counter"]
    assert parsed.flags["delay"] == "500ms"
    assert parsed.flags["increment"] == "1"
  end

  test "monkey-job accepts --json-events" do
    assert {:ok, parsed} =
             Parser.parse(["monkey-job", "count to 10", "--json-events"], %{})

    assert parsed.flags["json_events"] == true
  end

  test "benchmark accepts resident tree flags without splitting the shape" do
    assert {:ok, parsed} =
             Parser.parse(
               [
                 "benchmark",
                 "--scenario",
                 "agent-tree",
                 "--max-trees",
                 "2",
                 "--tree-shape",
                 "1,1,2,4",
                 "--tree-mode",
                 "resident"
               ],
               %{}
             )

    assert parsed.command == :benchmark
    assert parsed.flags["scenario"] == "agent-tree"
    assert parsed.flags["max_trees"] == "2"
    assert parsed.flags["tree_shape"] == "1,1,2,4"
    assert parsed.flags["tree_mode"] == "resident"
  end
end
