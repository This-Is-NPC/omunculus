defmodule Omunculus.GuiProjectsTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @fixtures """
  const place = id => ({id, socket: "/run/" + id + ".sock"});
  const conversation = (id, created_at) => ({id, created_at});
  const work = (state, updated_at) => ({state, updated_at});
  const input = fields => Object.assign({
    projects: [], conversations: {}, works: {}, summaries: {}, unreachable: new Set(), current: ""
  }, fields);
  const byId = rows => Object.fromEntries(rows.map(row => [row.id, row]));
  const check = (ok, what) => { if (!ok) throw Error(what); };
  """

  defp run!(assertions) do
    assert {"", 0} = GuiModules.run(["Projects"], @fixtures <> assertions)
  end

  test "rows count conversations, open works and the latest activity" do
    run!("""
    const rows = Projects.rows(input({
      projects: [place("agency")],
      conversations: {agency: [conversation("c1", "2026-11-03T10:00:00Z"), conversation("c2", "2026-11-03T12:00:00Z")]},
      works: {agency: [work("open", "2026-11-03T13:00:00Z"), work("done", "2026-11-03T09:00:00Z"), work("cancelled", "2026-11-03T08:00:00Z"), work("broken", "2026-11-03T11:00:00Z")]},
      summaries: {c1: {running: 1, waiting: 0}, c2: {running: 0, waiting: 0}},
      current: "agency"
    }));
    const row = rows[0];
    check(row.id === "agency" && row.socket === "/run/agency.sock", "place");
    check(row.current && row.reachable, "current " + JSON.stringify(row));
    check(row.conversations === 2 && row.openWorks === 2, "counts " + JSON.stringify(row));
    check(row.last === "2026-11-03T13:00:00Z", "last " + row.last);
    check(row.working === 1 && row.waiting === 0 && row.state === "working", "state " + row.state);
    """)
  end

  test "state: unreachable, then reading, then waiting over working, then idle" do
    run!("""
    const busy = [conversation("w", "2026-11-03T10:00:00Z")];
    const rows = byId(Projects.rows(input({
      projects: [place("gone"), place("fresh"), place("asks"), place("works"), place("quiet")],
      conversations: {gone: busy, asks: [conversation("a", "2026-11-03T10:00:00Z")], works: busy, quiet: []},
      summaries: {w: {running: 2, waiting: 3}, a: {running: 1, waiting: 2}},
      unreachable: new Set(["gone"])
    })));
    check(rows.gone.state === "unreachable" && !rows.gone.reachable, "unreachable " + rows.gone.state);
    check(rows.gone.waiting === 0 && rows.gone.working === 0 && rows.gone.conversations === 1, "stale " + JSON.stringify(rows.gone));
    check(rows.fresh.state === "reading" && rows.fresh.conversations === 0 && rows.fresh.last === "", "reading " + rows.fresh.state);
    check(rows.asks.state === "waiting" && rows.asks.waiting === 2 && rows.asks.working === 1, "waiting " + rows.asks.state);
    check(rows.works.state === "waiting" && rows.works.waiting === 3, "waiting first " + rows.works.state);
    check(rows.quiet.state === "idle" && !rows.quiet.current, "idle " + rows.quiet.state);
    """)
  end

  test "sort: waiting, working, the latest activity, then the id" do
    run!("""
    const row = (id, waiting, working, last) => ({id, waiting, working, last});
    const rows = [
      row("b-idle", 0, 0, "2026-11-03T10:00:00Z"),
      row("a-idle", 0, 0, "2026-11-03T10:00:00Z"),
      row("never", 0, 0, ""),
      row("recent", 0, 0, "2026-11-03T12:00:00Z"),
      row("works", 0, 2, ""),
      row("works-more", 0, 3, ""),
      row("asks", 1, 0, ""),
      row("asks-more", 2, 0, "")
    ];
    const order = Projects.sort(rows).map(row => row.id).join();
    check(order === "asks-more,asks,works-more,works,recent,a-idle,b-idle,never", "order " + order);
    check(rows[0].id === "b-idle", "sort keeps its input");
    """)
  end

  test "filter by state chip and by the words of the id" do
    run!("""
    const rows = [
      {id: "agency", state: "waiting"}, {id: "Bakery-site", state: "working"}, {id: "dev", state: "idle"}
    ];
    const ids = (text, chip) => Projects.filter(rows, text, chip).map(row => row.id).join();
    check(ids("", "") === "agency,Bakery-site,dev", "all");
    check(ids("", "waiting") === "agency", "waiting");
    check(ids("", "working") === "Bakery-site", "working");
    check(ids("bakery SITE", "") === "Bakery-site", "words " + ids("bakery SITE", ""));
    check(ids("  ", "") === "agency,Bakery-site,dev", "blank");
    check(ids("dev", "waiting") === "", "both");
    """)
  end

  test "elsewhere sums the waiting of every project but the open one" do
    run!("""
    const rows = Projects.rows(input({
      projects: [place("agency"), place("dev"), place("down")],
      conversations: {agency: [conversation("a", "")], dev: [conversation("d", "")], down: [conversation("x", "")]},
      summaries: {a: {waiting: 2}, d: {waiting: 1}, x: {waiting: 5}},
      unreachable: new Set(["down"]),
      current: "agency"
    }));
    check(Projects.elsewhere(rows) === 1, "elsewhere " + Projects.elsewhere(rows));
    """)
  end
end
