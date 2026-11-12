for file <- ~w(task score selftest), do: Code.require_file("../../eval/lib/#{file}.ex", __DIR__)

defmodule Omunculus.EvalImportTest do
  use ExUnit.Case, async: true

  alias EquivalentExchange.{Selftest, Task}
  alias Omunculus.Fixtures

  @root Path.expand("../..", __DIR__)
  @fixtures Path.join(@root, "eval/fixtures")

  defp import!(script, args) do
    {said, status} =
      System.cmd(Path.join(@root, "scripts/#{script}"), args, stderr_to_stdout: true)

    assert status == 0, said
  end

  defp git!(dir, args) do
    {out, 0} =
      System.cmd("git", ["-C", dir, "-c", "user.name=f", "-c", "user.email=f@x" | args],
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  defp proved?(task), do: Enum.all?(task.configurations, &(Selftest.problems(task, &1) == []))

  test "a Terminal-Bench folder becomes a task whose solution passes and whose bare workspace fails" do
    out = Fixtures.tmp_dir()

    import!("eval-import-terminal-bench", [
      Path.join(@fixtures, "terminal-bench/hello-file"),
      "--out",
      out
    ])

    dir = Path.join(out, "terminal-bench/hello-file")
    task = Task.load!(dir, "")

    assert task.id == "terminal-bench/hello-file"
    assert task.instruction =~ "write greeting.txt"
    assert File.exists?(Path.join(dir, "workspace/data/names.txt"))
    refute File.exists?(Path.join(dir, "workspace/tests"))
    assert proved?(task)
  end

  describe "SWE-bench" do
    setup do
      base = Path.join(@fixtures, "swe-bench")
      repos = Fixtures.tmp_dir()
      repo = Path.join(repos, "fixture__calc")
      File.cp_r!(Path.join(base, "base"), repo)
      git!(repo, ["init", "-q"])
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-qm", "base"])
      sha = git!(repo, ["rev-parse", "HEAD"])

      # A later commit proves the workspace is the base commit, not the tip.
      File.write!(Path.join(repo, "calc.py"), "# later\n")
      git!(repo, ["commit", "-qam", "later"])

      instance = %{
        "instance_id" => "fixture__calc-1",
        "repo" => "fixture/calc",
        "base_commit" => sha,
        "problem_statement" => File.read!(Path.join(base, "problem.md")),
        "test_patch" => File.read!(Path.join(base, "test.patch")),
        "patch" => File.read!(Path.join(base, "gold.patch")),
        "test_cmd" => "python3 -m unittest"
      }

      {:ok, repos: repos, instance: instance}
    end

    defp convert(instance, repos) do
      out = Fixtures.tmp_dir()
      jsonl = Path.join(out, "instances.jsonl")
      File.write!(jsonl, Jason.encode!(instance) <> "\n")
      import!("eval-import-swe-bench", [jsonl, "--repos", repos, "--out", out])
      Task.load!(Path.join(out, "swe-bench/fixture__calc-1"), "")
    end

    test "an instance runs its fail-to-pass and pass-to-pass tests", %{
      repos: repos,
      instance: instance
    } do
      instance =
        Map.merge(instance, %{
          "FAIL_TO_PASS" => Jason.encode!(["test_calc.Calc.test_sub"]),
          "PASS_TO_PASS" => ["test_calc.Calc.test_add"]
        })

      task = convert(instance, repos)

      assert task.id == "swe-bench/fixture__calc-1"
      assert task.instruction =~ "Fix calc.sub"
      assert File.read!(Path.join(task.dir, "workspace/calc.py")) =~ "def sub"

      assert git!(Path.join(task.dir, "workspace"), ["rev-parse", "HEAD"]) ==
               instance["base_commit"]

      assert proved?(task)
    end

    test "the Pro field names and a failing pass-to-pass test", %{
      repos: repos,
      instance: instance
    } do
      instance =
        Map.merge(instance, %{
          "fail_to_pass" => Jason.encode!(["test_calc.Calc.test_sub"]),
          "pass_to_pass" => Jason.encode!(["test_calc.Calc.test_missing"])
        })

      task = convert(instance, repos)

      assert [problem] = Selftest.problems(task, "solo")
      assert problem =~ "PASS_TO_PASS tests failed"
    end
  end
end
