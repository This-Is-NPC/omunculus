defmodule Omunculus.Process.LogTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.Process.Log
  alias Omunculus.ProcessFixtures
  alias Omunculus.Store

  defp build(conn, last \\ nil) do
    {:ok, raw} = Store.log(conn, last)
    Log.build(raw)
  end

  defp work(log, id), do: Enum.find(log.works, &(&1.id == id))

  test "a work's stages are the ones it entered, in order", %{conn: conn} do
    %{works: works} = ProcessFixtures.seed(conn)
    log = build(conn)

    assert work(log, works.done_a).stages == ["to_do", "review"]
    assert work(log, works.cancelled).stages == ["to_do"]
    assert work(log, works.skipped).stages == ["review"]
    assert work(log, works.back).stages == ["to_do", "review", "to_do", "review"]
    assert work(log, works.repeated).stages == ["to_do", "to_do", "review"]
  end

  test "the calls are the model's: the run's end and what comes before its first reply are left out",
       %{conn: conn} do
    %{works: works} = ProcessFixtures.seed(conn)
    log = build(conn)

    calls = for %{kind: :call, activity: name} <- work(log, works.done_a).events, do: name
    assert calls == ["read", "read", "write", "bash", "continue", "read", "continue"]
  end

  test "a call carries its agent, its duration and whether it was refused", %{conn: conn} do
    %{works: works} = ProcessFixtures.seed(conn)
    events = work(build(conn), works.cancelled).events

    assert %{attrs: %{"ok" => false, "agent" => "worker", "duration" => 1.0}} =
             Enum.find(events, &(&1.activity == "bash"))

    assert %{attrs: %{"ok" => true, "duration" => 2.0}} =
             Enum.find(events, &(&1.activity == "write"))
  end

  test "a reply carries its model, its cost and its tokens", %{conn: conn} do
    %{works: works} = ProcessFixtures.seed(conn)
    events = work(build(conn), works.cancelled).events

    assert %{attrs: %{"model" => "synthetic-1", "usd" => 1.0, "tokens" => 120, "duration" => 5.0}} =
             Enum.find(events, &(&1.kind == :reply))
  end

  test "a work ends when it is done or cancelled", %{conn: conn} do
    %{works: works} = ProcessFixtures.seed(conn)
    log = build(conn)

    assert [%{activity: "work done"}] =
             Enum.filter(work(log, works.done_a).events, &(&1.kind == :end))

    assert [%{activity: "work cancelled"}] =
             Enum.filter(work(log, works.cancelled).events, &(&1.kind == :end))

    assert [] = Enum.filter(work(log, works.open).events, &(&1.kind == :end))
  end

  test "requests and artifacts are events and objects", %{conn: conn} do
    %{works: works, conversations: [conversation | _]} = ProcessFixtures.seed(conn)
    {:ok, %{runs: [run | _]}} = Store.log(conn, nil)
    request = ProcessFixtures.traffic(conn, conversation, works.done_a, run.id)

    log = build(conn)
    activities = Enum.map(log.events, & &1.activity)
    assert "request raised" in activities and "request answered" in activities
    assert "artifact written" in activities

    assert Enum.any?(log.objects, &(&1.type == "request" and &1.id == request))
    assert Enum.any?(log.objects, &(&1.type == "artifact" and &1.id == "#{conversation}/plan.md"))
  end

  test "last keeps the newest conversations", %{conn: conn} do
    %{works: works, conversations: [_older, newest]} = ProcessFixtures.seed(conn)
    log = build(conn, 1)

    assert Enum.sort(Enum.map(log.works, & &1.id)) ==
             Enum.sort([works.back, works.repeated, works.open])

    assert Enum.all?(log.events, fn event ->
             {"conversation", newest, "in conversation"} in event.objects
           end)
  end

  test "the log is in the order the events were recorded", %{conn: conn} do
    ProcessFixtures.seed(conn)
    sequences = Enum.map(build(conn).events, & &1.seq)
    assert sequences == Enum.sort(sequences)
  end
end
