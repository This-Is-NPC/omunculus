defmodule Omunculus.Tools.FormatTest do
  use ExUnit.Case, async: true

  alias Omunculus.ExecutionPolicyFixtures
  alias Omunculus.Tools.{Edit, Patch, Write}

  setup do
    root = Omunculus.Fixtures.tmp_dir()
    # A fake formatter: it upper-cases the file it is given.
    File.write!(
      Path.join(root, "upcase.sh"),
      ~S(tr a-z A-Z < "$1" > "$1.tmp" && mv "$1.tmp" "$1")
    )

    File.write!(Path.join(root, "unchanged.sh"), "exit 0")
    File.write!(Path.join(root, "broken.sh"), ~S(echo "syntax error in $1" >&2; exit 3))
    %{root: root, policy: ExecutionPolicyFixtures.policy(root, writable: true)}
  end

  defp input(name, args, root, format) do
    %{
      name: name,
      args: args,
      view: %{"format" => format},
      run_id: nil,
      work_id: nil,
      workspace: nil,
      roots: [root]
    }
  end

  defp write(root, format, path \\ "a.txt") do
    input("write", %{"path" => path, "content" => "hello"}, root, format)
  end

  describe "without a command for the file" do
    test "nothing runs without the table", %{root: root, policy: policy} do
      assert %{"ok" => true, "output" => ""} = Write.run(write(root, %{}), policy)
      assert File.read!(Path.join(root, "a.txt")) == "hello"
    end

    test "nothing runs for an extension the table does not list", %{root: root, policy: policy} do
      format = %{"md" => ["sh", "upcase.sh", "{file}"]}

      assert %{"ok" => true, "output" => ""} = Write.run(write(root, format), policy)
      assert File.read!(Path.join(root, "a.txt")) == "hello"
    end

    test "a command that is not a list with {file} is said in words", %{
      root: root,
      policy: policy
    } do
      for format <- [%{"txt" => "upcase"}, %{"txt" => ["sh", "upcase.sh"]}, %{"txt" => []}] do
        assert %{"ok" => true, "output" => output} = Write.run(write(root, format), policy)

        assert output =~
                 "a.txt was written but not formatted: [settings.format] txt must be a command"

        assert File.read!(Path.join(root, "a.txt")) == "hello"
      end
    end
  end

  describe "with a formatter" do
    @describetag :sandbox

    test "write formats the file and says so", %{root: root, policy: policy} do
      format = %{"txt" => ["sh", "upcase.sh", "{file}"]}

      assert %{"ok" => true, "output" => output} = Write.run(write(root, format), policy)

      assert output ==
               "a.txt was formatted by `sh upcase.sh a.txt`: read it again before editing it."

      assert File.read!(Path.join(root, "a.txt")) == "HELLO"
    end

    test "a formatter that leaves the file as written says nothing", %{root: root, policy: policy} do
      format = %{"txt" => ["sh", "unchanged.sh", "{file}"]}

      assert %{"ok" => true, "output" => ""} = Write.run(write(root, format), policy)
      assert File.read!(Path.join(root, "a.txt")) == "hello"
    end

    test "edit formats the edited file", %{root: root, policy: policy} do
      File.write!(Path.join(root, "a.txt"), "hello world")
      args = %{"path" => "a.txt", "edits" => [%{"old" => "world", "new" => "there"}]}
      format = %{"txt" => ["sh", "upcase.sh", "{file}"]}

      assert %{"ok" => true, "output" => output} =
               Edit.run(input("edit", args, root, format), policy)

      assert output =~ "a.txt was formatted"
      assert File.read!(Path.join(root, "a.txt")) == "HELLO THERE"
    end

    test "patch formats each file it wrote, by extension, and not a deleted one", %{
      root: root,
      policy: policy
    } do
      File.write!(Path.join(root, "old.txt"), "gone")
      File.write!(Path.join(root, "b.md"), "keep\n")

      patch = """
      *** Begin Patch
      *** Add File: new.txt
      +added
      *** Update File: b.md
      @@
      -keep
      +kept
      *** Delete File: old.txt
      *** End Patch
      """

      format = %{"txt" => ["sh", "upcase.sh", "{file}"]}

      assert %{"ok" => true, "output" => output} =
               Patch.run(input("patch", %{"patch" => patch}, root, format), policy)

      assert output =~ "added new.txt\nupdated b.md\ndeleted old.txt\nnew.txt was formatted"
      assert File.read!(Path.join(root, "new.txt")) == "ADDED\n"
      assert File.read!(Path.join(root, "b.md")) == "kept\n"
      refute File.exists?(Path.join(root, "old.txt"))
    end

    test "a failing formatter is reported and the edit stands", %{root: root, policy: policy} do
      format = %{"txt" => ["sh", "broken.sh", "{file}"]}

      assert %{"ok" => true, "output" => output} = Write.run(write(root, format), policy)

      assert output ==
               "a.txt was written but not formatted: `sh broken.sh a.txt` exited with status 3. The change stands.\nsyntax error in #{Path.join(root, "a.txt")}"

      assert File.read!(Path.join(root, "a.txt")) == "hello"
    end

    test "a formatter that is not there is a failure in words too", %{root: root, policy: policy} do
      format = %{"txt" => ["no-such-formatter", "{file}"]}

      assert %{"ok" => true, "output" => output} = Write.run(write(root, format), policy)

      assert output =~
               "a.txt was written but not formatted: `no-such-formatter a.txt` exited with status 127"
    end

    test "the formatter runs under the run's policy: it cannot write where the run cannot", %{
      root: root
    } do
      File.write!(Path.join(root, "other.txt"), "keep")

      policy =
        ExecutionPolicyFixtures.policy(root, writable: true, read_only: [Path.join(root, "kept")])

      File.mkdir_p!(Path.join(root, "kept"))
      format = %{"txt" => ["sh", "-c", ~S(echo x > "$1"), "sh", Path.join(root, "kept/f.txt")]}

      assert %{"ok" => true, "output" => output} = Write.run(write(root, format), policy)
      assert output =~ "not formatted"
      refute File.exists?(Path.join(root, "kept/f.txt"))
    end
  end
end
