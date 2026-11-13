defmodule Omunculus.Process.ConformanceTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.Process.{Conformance, Log}
  alias Omunculus.ProcessFixtures
  alias Omunculus.Store

  defp steps, do: [%{name: "to_do", agent: "worker"}, %{name: "review", agent: "reviewer"}]

  defp check(conn) do
    seeded = ProcessFixtures.seed(conn)
    {:ok, raw} = Store.log(conn, nil)
    {seeded, Conformance.check(Log.build(raw).works, %{"delivery" => steps()})}
  end

  defp ids(result, kind), do: Enum.map(result.deviations[kind], & &1.work.id)

  test "the works that follow the workflow are its fitness", %{conn: conn} do
    {_seeded, result} = check(conn)
    assert %{checked: 8, followed: 4} = result
  end

  test "each deviation kind names its works", %{conn: conn} do
    {%{works: works}, result} = check(conn)

    assert ids(result, "skipped stage") == [works.skipped]
    assert ids(result, "repeated stage") == [works.repeated]
    assert ids(result, "out of order") == [works.back]
    assert ids(result, "ended outside its last stage") == [works.cancelled]
  end

  test "a deviation says what it was", %{conn: conn} do
    {_seeded, result} = check(conn)
    assert [%{detail: "to_do before review"}] = result.deviations["skipped stage"]
    assert [%{detail: "back to to_do"}] = result.deviations["out of order"]

    assert [%{detail: "ended cancelled in to_do"}] =
             result.deviations["ended outside its last stage"]
  end

  test "a work of a workflow the config lacks is not checked", %{conn: conn} do
    ProcessFixtures.seed(conn)
    {:ok, raw} = Store.log(conn, nil)
    assert %{checked: 0, followed: 0} = Conformance.check(Log.build(raw).works, %{})
  end

  test "a stage the workflow does not declare is out of order" do
    work = %{workflow: "delivery", stages: ["to_do", "qa", "review"], state: "done", events: []}
    result = Conformance.check([work], %{"delivery" => steps()})
    assert [%{detail: "qa is not declared"}] = result.deviations["out of order"]
  end
end
