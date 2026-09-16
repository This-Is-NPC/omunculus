defmodule Omunculus.MatrixTest do
  @moduledoc """
  Walks the twelve D0/D1/D2 × H0/H1 × W0/W1 cells of spec §6 through the
  same "conte até 5" task, driven by `Omunculus.Model.Battery`.
  """

  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Id, Project, Store}
  alias Omunculus.Model.Battery
  alias Omunculus.Store.Query

  @concierge_d0_tools ~w(bench break continue fs.read store)
  @concierge_d1_tools ~w(break catalog continue delegate fs.read store)
  @concierge_d2_tools ~w(catalog delegate fs.read sequence store)
  @worker_tools ~w(bench break comment continue fs.read notify request_access)
  @worker_d2_tools ~w(bench comment continue fs.read notify request_access)
  @manager_tools ~w(delegate fs.read sequence store)

  @concierge_text "Você é o concierge do projeto. Leia a message, use as tools em `tools.*` quando precisar e responda."
  @worker_text "Você é o worker. Faça o work que recebeu, comente o progresso e chame continue quando terminar a etapa."
  @manager_text "Você é o manager. Delegue para quem está abaixo e revise quando o work voltar."
  @observer_text "Você é o observer. Registre o aviso."

  setup do
    dir = Path.join(System.tmp_dir!(), Id.new())
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp open(dir) do
    {:ok, project} = Project.open(dir)
    project
  end

  defp concierge_section(tools) do
    """
    [agents.concierge]
    depth = 0
    tools = #{inspect(tools)}
    text = "#{@concierge_text}"
    """
  end

  defp agent_section(name, depth, tools, text) do
    """

    [agents.#{name}]
    depth = #{depth}
    tools = #{inspect(tools)}
    text = "#{text}"
    """
  end

  defp worker_section(tools \\ @worker_tools, depth \\ 1),
    do: agent_section("worker", depth, tools, @worker_text)

  defp manager_section, do: agent_section("manager", 1, @manager_tools, @manager_text)

  defp config_toml(0, false), do: concierge_section(@concierge_d0_tools)

  defp config_toml(0, true) do
    concierge_section(@concierge_d0_tools) <>
      """

      [workflows.delivery]
      steps = [
        { name = "to_do", agent = "concierge" },
        { name = "review", agent = "concierge", deny = ["bench"] },
      ]

      [policy]
      workflow = "delivery"
      """
  end

  defp config_toml(1, false), do: concierge_section(@concierge_d1_tools) <> worker_section()

  defp config_toml(1, true) do
    concierge_section(@concierge_d1_tools) <>
      worker_section() <>
      """

      [workflows.delivery]
      steps = [
        { name = "to_do", agent = "worker" },
        { name = "review", agent = "concierge", deny = ["bench"] },
      ]

      [policy.depth.1]
      workflow = "delivery"
      """
  end

  defp config_toml(2, false) do
    concierge_section(@concierge_d2_tools) <>
      manager_section() <>
      worker_section(@worker_d2_tools, 2)
  end

  defp config_toml(2, true) do
    concierge_section(@concierge_d2_tools) <>
      manager_section() <>
      worker_section(@worker_d2_tools, 2) <>
      """

      [workflows.delivery]
      steps = [
        { name = "to_do", agent = "worker" },
        { name = "review", agent = "manager", deny = ["bench"] },
      ]

      [policy.depth.2]
      workflow = "delivery"
      """
  end

  defp write_config(dir, depth, workflow?),
    do: File.write!(Path.join(dir, "omunculus.toml"), config_toml(depth, workflow?))

  defp add_observer_hook(dir) do
    config = File.read!(Path.join(dir, "omunculus.toml"))

    File.write!(
      Path.join(dir, "omunculus.toml"),
      config <>
        """

        [agents.observer]
        depth = 0
        tools = ["comment"]
        text = "#{@observer_text}"
        """
    )

    hook_dir = Path.join([dir, "tools", "on-notify"])
    File.mkdir_p!(hook_dir)

    File.write!(Path.join(hook_dir, "hook.toml"), """
    name = "on-notify"
    kind = "hook"
    events = ["notify"]
    agent = "observer"
    command = ["./run"]
    """)

    run_path = Path.join(hook_dir, "run")

    File.write!(run_path, """
    #!/bin/sh
    echo '{"ok": true, "output": "", "emit": []}'
    """)

    File.chmod!(run_path, 0o755)
  end

  defp run_cell(dir, depth, hook?, workflow?) do
    write_config(dir, depth, workflow?)
    if hook?, do: add_observer_hook(dir)

    assert {:ok, ""} = CLI.run(["send", "conte até 5"], dir, &Battery.complete/3)
  end

  defp counter_value(dir),
    do: dir |> Path.join(".omunculus/counter") |> File.read!() |> String.trim()

  defp counted_work(conn) do
    assert {:ok, [comment]} =
             Query.all(conn, "SELECT * FROM comments WHERE body = ?", ["contei até 5"])

    assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [comment.work_id])
    work
  end

  defp continue_events(conn) do
    assert {:ok, events} = Store.replay(conn, :project)
    events |> Enum.filter(&(&1.type == "continue")) |> Enum.map(&Jason.decode!(&1.body))
  end

  defp assert_counted_to_five(dir, conn) do
    assert counter_value(dir) == "5"
    counted_work(conn)
  end

  defp assert_workflow_on(conn, work) do
    assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [work.id])
    assert work.state == "done"
    assert [%{"to" => "review"}, %{"to" => nil}] = continue_events(conn)
  end

  defp assert_workflow_off(conn), do: assert(continue_events(conn) == [])

  defp assert_observer_reacted(conn) do
    assert {:ok, [_reaction]} =
             Query.all(conn, "SELECT * FROM runs WHERE via = 'on-notify' AND agent = 'observer'")

    assert {:ok, [_comment]} = Query.all(conn, "SELECT * FROM comments WHERE body = 'observado'")
  end

  defp refute_observer_reacted(conn),
    do: assert({:ok, []} = Query.all(conn, "SELECT * FROM runs WHERE via = 'on-notify'"))

  defp assert_child_delegated(conn) do
    assert {:ok, [_worker_run]} =
             Query.all(conn, "SELECT * FROM runs WHERE agent = 'worker' AND depth = '1'")

    assert {:ok, [parent]} = Query.all(conn, "SELECT * FROM works WHERE parent_id IS NULL")
    assert parent.state == "open"

    assert {:ok, parent_runs} =
             Query.all(conn, "SELECT * FROM runs WHERE work_id = ?", [parent.id])

    assert length(parent_runs) >= 2
  end

  defp assert_worker_ran_at_depth_two(conn) do
    assert {:ok, [_worker_run]} =
             Query.all(conn, "SELECT * FROM runs WHERE agent = 'worker' AND depth = '2'")
  end

  defp assert_reopened_to_root(conn, work) do
    assert {:ok, manager_work} =
             Query.one(conn, "SELECT * FROM works WHERE id = ?", [work.parent_id])

    assert manager_work.state == "done"

    assert {:ok, root} =
             Query.one(conn, "SELECT * FROM works WHERE id = ?", [manager_work.parent_id])

    assert root.parent_id == nil
    assert root.state == "open"
  end

  test "D0-H0-W0", %{dir: dir} do
    run_cell(dir, 0, false, false)
    project = open(dir)

    work = assert_counted_to_five(dir, project.conn)
    assert work.parent_id == nil
    assert work.state == "open"

    assert_workflow_off(project.conn)
    refute_observer_reacted(project.conn)

    Project.close(project)
  end

  test "D0-H1-W0", %{dir: dir} do
    run_cell(dir, 0, true, false)
    project = open(dir)

    work = assert_counted_to_five(dir, project.conn)
    assert work.state == "open"

    assert_workflow_off(project.conn)
    assert_observer_reacted(project.conn)

    Project.close(project)
  end

  test "D0-H0-W1", %{dir: dir} do
    run_cell(dir, 0, false, true)
    project = open(dir)

    work = assert_counted_to_five(dir, project.conn)
    assert_workflow_on(project.conn, work)
    refute_observer_reacted(project.conn)

    Project.close(project)
  end

  test "D0-H1-W1", %{dir: dir} do
    run_cell(dir, 0, true, true)
    project = open(dir)

    work = assert_counted_to_five(dir, project.conn)
    assert_workflow_on(project.conn, work)
    assert_observer_reacted(project.conn)

    Project.close(project)
  end

  test "D1-H0-W0", %{dir: dir} do
    run_cell(dir, 1, false, false)
    project = open(dir)

    work = assert_counted_to_five(dir, project.conn)
    assert work.parent_id != nil
    assert work.state == "done"

    assert_workflow_off(project.conn)
    assert_child_delegated(project.conn)
    refute_observer_reacted(project.conn)

    Project.close(project)
  end

  test "D1-H1-W0", %{dir: dir} do
    run_cell(dir, 1, true, false)
    project = open(dir)

    work = assert_counted_to_five(dir, project.conn)
    assert work.state == "done"

    assert_workflow_off(project.conn)
    assert_child_delegated(project.conn)
    assert_observer_reacted(project.conn)

    Project.close(project)
  end

  test "D1-H0-W1", %{dir: dir} do
    run_cell(dir, 1, false, true)
    project = open(dir)

    work = assert_counted_to_five(dir, project.conn)
    assert_workflow_on(project.conn, work)
    assert_child_delegated(project.conn)
    refute_observer_reacted(project.conn)

    Project.close(project)
  end

  test "D1-H1-W1", %{dir: dir} do
    run_cell(dir, 1, true, true)
    project = open(dir)

    work = assert_counted_to_five(dir, project.conn)
    assert_workflow_on(project.conn, work)
    assert_child_delegated(project.conn)
    assert_observer_reacted(project.conn)

    Project.close(project)
  end

  test "D2-H0-W0", %{dir: dir} do
    run_cell(dir, 2, false, false)
    project = open(dir)

    work = assert_counted_to_five(dir, project.conn)
    assert work.state == "done"
    assert_worker_ran_at_depth_two(project.conn)
    assert_reopened_to_root(project.conn, work)

    assert_workflow_off(project.conn)
    refute_observer_reacted(project.conn)

    Project.close(project)
  end

  test "D2-H1-W0", %{dir: dir} do
    run_cell(dir, 2, true, false)
    project = open(dir)

    work = assert_counted_to_five(dir, project.conn)
    assert work.state == "done"
    assert_worker_ran_at_depth_two(project.conn)
    assert_reopened_to_root(project.conn, work)

    assert_workflow_off(project.conn)
    assert_observer_reacted(project.conn)

    Project.close(project)
  end

  test "D2-H0-W1", %{dir: dir} do
    run_cell(dir, 2, false, true)
    project = open(dir)

    work = assert_counted_to_five(dir, project.conn)
    assert_worker_ran_at_depth_two(project.conn)
    assert_workflow_on(project.conn, work)
    assert_reopened_to_root(project.conn, work)

    refute_observer_reacted(project.conn)

    Project.close(project)
  end

  test "D2-H1-W1", %{dir: dir} do
    run_cell(dir, 2, true, true)
    project = open(dir)

    work = assert_counted_to_five(dir, project.conn)
    assert_worker_ran_at_depth_two(project.conn)
    assert_workflow_on(project.conn, work)
    assert_reopened_to_root(project.conn, work)

    assert_observer_reacted(project.conn)

    Project.close(project)
  end
end
