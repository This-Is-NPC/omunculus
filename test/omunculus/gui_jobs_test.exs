defmodule Omunculus.GuiJobsTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @fixtures """
  const check = (ok, what) => { if (!ok) throw Error(what); };
  const sorted = value => Array.isArray(value) ? value.map(sorted)
    : value && typeof value === "object" ? Object.fromEntries(Object.keys(value).sort().map(key => [key, sorted(value[key])])) : value;
  const same = (got, want, what) => check(JSON.stringify(sorted(got)) === JSON.stringify(sorted(want)), what + ": " + JSON.stringify(got));
  const agent = name => ({kind: "agent", agent: name});
  """

  defp run!(assertions, env \\ []) do
    assert {"", 0} = GuiModules.run(["Time", "Usage", "Jobs"], @fixtures <> assertions, env)
  end

  test "a schedule reads in words" do
    run!("""
    same(Jobs.when("every 30m"), "every 30 minutes", "minutes");
    same(Jobs.when("every 1h"), "every hour", "hour");
    same(Jobs.when("every 2h"), "every 2 hours", "hours");
    same(Jobs.when("daily at 7:00"), "every day at 07:00", "daily");
    same(Jobs.when("0 9 * * 1"), "every Monday at 09:00", "weekday");
    same(Jobs.when("30 18 * * 7"), "every Sunday at 18:30", "sunday");
    same(Jobs.when("0 9 * * 1-5"), "every weekday at 09:00", "weekdays");
    same(Jobs.when("15 8 * * *"), "every day at 08:15", "cron daily");
    same(Jobs.when("0 6 1 * *"), "on day 1 of every month at 06:00", "monthly");
    same(Jobs.when("*/10 * * * *"), "every 10 minutes", "step");
    same(Jobs.when("0 * * * *"), "every hour", "cron hour");
    same(Jobs.when("5 4 * 2 *"), "on the schedule 5 4 * 2 *", "no words");
    same(Jobs.when(""), "", "empty");
    """)
  end

  test "states are an icon and a word" do
    run!("""
    same(Jobs.mark("paused"), {icon: "warning", word: "PAUSED", tone: "warning"}, "paused");
    same(Jobs.mark("succeeded").word, "SUCCEEDED", "fire");
    same(Jobs.mark("failed").icon, "close", "failed");
    same(Jobs.mark("odd").word, "ODD", "unknown");
    """)
  end

  test "figures read as the lists show them" do
    run!("""
    same(Jobs.rate({success_rate: 0.923}), "92%", "rate");
    same(Jobs.rate({success_rate: null}), "\\u2014", "no rate");
    same(Jobs.cost(0.0123), "US$ 0.01", "cost");
    same(Jobs.cost(null), "\\u2014", "no cost");
    same(Jobs.tokens(950), "950", "small");
    same(Jobs.tokens(12400), "12.4k", "k");
    same(Jobs.tokens(1200000), "1.2M", "M");
    same(Jobs.took(850), "850 ms", "ms");
    same(Jobs.took(12000), "12 s", "s");
    same(Jobs.took(185000), "3 min 05 s", "min");
    same(Jobs.took(0), "\\u2014", "none");
    """)
  end

  test "an origin names the channel and the author" do
    run!("""
    same(Jobs.origin({origin: {channel: "proposal", author: agent("seller")}}), "proposal by seller", "agent");
    same(Jobs.origin({origin: {channel: "console", author: {kind: "human", issuer: "local", subject: "ana"}}}), "console by local:ana", "human");
    same(Jobs.origin({origin: {channel: "scheduler", author: {kind: "harness"}}}), "scheduler by the harness", "harness");
    same(Jobs.origin({}), "", "none");
    """)
  end

  test "the fires fold from their events, newest first" do
    run!("""
    const events = [
      {op: "create", at: "2026-11-10T07:00:00Z"},
      {op: "fire", at: "2026-11-11T07:00:00Z", fire_id: "a", state: "due", scheduled_for: "2026-11-11T07:00:00Z", version: 1},
      {op: "fire", at: "2026-11-11T07:00:01Z", fire_id: "a", state: "running", conversation_id: "c1", run_ids: ["r1"]},
      {op: "fire", at: "2026-11-11T07:00:20Z", fire_id: "a", state: "succeeded", duration_ms: 19000, calls: 3, input_tokens: 900, output_tokens: 100, usd: 0.02},
      {op: "fire", at: "2026-11-12T07:00:00Z", fire_id: "b", state: "due", scheduled_for: "2026-11-12T07:00:00Z", version: 2},
      {op: "fire", at: "2026-11-12T07:00:00Z", fire_id: "b", state: "skipped", reason: "the condition said no"}
    ];
    const rows = Jobs.fires(events);
    check(rows.length === 2, "two fires");
    same(rows[0].id, "b", "newest first");
    same(rows[0].state, "skipped", "latest state");
    same(rows[0].reason, "the condition said no", "reason");
    same(rows[0].usd, null, "no cost for a skip");
    same(rows[1], {id: "a", state: "succeeded", when: "2026-11-11T07:00:00Z", version: 1, manual: false,
      took: 19000, calls: 3, tokens: 1000, usd: 0.02, conversation: "c1", reason: ""}, "merged");
    """)
  end

  test "the changes list creation, edits and moves with who and where" do
    run!("""
    const author = {kind: "human", issuer: "local", subject: "ana"};
    const rows = Jobs.changes([
      {op: "create", at: "t1", version: 1, origin: {author, channel: "cli"}},
      {op: "change", at: "t2", version: 2, fields: {schedule: "daily at 8:00", conversation_id: null}, origin: {author: agent("seller"), channel: "proposal"}},
      {op: "transition", at: "t3", from: "active", to: "paused", reason: "holiday", origin: {author, channel: "console"}},
      {op: "fire", at: "t4", fire_id: "a", state: "due"}
    ]);
    same(rows.map(row => row.text), ["active to paused: holiday", "changed schedule, conversation id", "created"], "texts");
    same(rows[1], {version: 2, at: "t2", author: "seller", channel: "proposal", text: "changed schedule, conversation id"}, "an edit");
    """)
  end

  test "the jobs of a state, archived ones apart" do
    run!("""
    const items = [{state: "active"}, {state: "paused"}, {state: "archived"}];
    check(Jobs.inState(items, "").length === 2, "all but archived");
    check(Jobs.inState(items, "archived").length === 1, "archived");
    check(Jobs.inState(items, "paused")[0].state === "paused", "paused");
    """)
  end

  test "an end date is read in the person's time" do
    run!(
      """
      same(Jobs.endInstant("2026-12-31 18:00"), "2026-12-31T21:00:00.000Z", "time");
      same(Jobs.endInstant("2026-12-31"), "2027-01-01T02:59:00.000Z", "the day's last minute");
      same(Jobs.endInstant("soon"), "", "not a date");
      same(Jobs.endText("2026-12-31T21:00:00.000Z"), "2026-12-31 18:00", "back");
      same(Jobs.endText(null), "", "none");
      """,
      [{"TZ", "America/Sao_Paulo"}]
    )
  end

  test "the form says what is missing, in order" do
    run!("""
    const form = fields => Jobs.blank(Object.assign({name: "morning", target: "front", message: "go", schedule: "daily at 7:00", timezone: "Europe/Paris"}, fields));
    same(Jobs.problem(form({}), true), "", "ready");
    check(Jobs.problem(form({name: "no way"}), true).startsWith("Name it"), "name");
    same(Jobs.problem(form({name: "no way"}), false), "", "an edit keeps its name");
    same(Jobs.problem(form({target: "", kind: "workflow"}), true), "Choose the workflow it runs.", "target");
    same(Jobs.problem(form({message: "  "}), true), "Write the message it sends.", "message");
    same(Jobs.problem(form({schedule: ""}), true), "Say when it runs.", "schedule");
    same(Jobs.problem(form({timezone: ""}), true), "Give the time zone the schedule is in.", "zone");
    same(Jobs.problem(form({mode: "fixed"}), true), "Choose the conversation it goes to.", "conversation");
    check(Jobs.problem(form({end: "someday"}), true).startsWith("Write the end"), "end");
    """)
  end

  test "a form becomes a create body or an edit body" do
    run!("""
    const form = Jobs.blank({name: "morning", target: "front", message: " summarize ", schedule: "daily at 7:00", timezone: "Europe/Paris",
      mode: "fixed", conversation: "c1", delivery: "owner_inbox"});
    same(Jobs.body(form, false), {name: "morning", channel: "console", agent: "front", message: "summarize", schedule: "daily at 7:00",
      timezone: "Europe/Paris", conversation_id: "c1", delivery: "owner_inbox"}, "create");
    same(Jobs.body(Object.assign({}, form, {kind: "workflow", target: "review", condition: "", delivery: ""}), true),
      {message: "summarize", schedule: "daily at 7:00", timezone: "Europe/Paris", condition: "", end_at: "", delivery: "", agent: "", workflow: "review"}, "edit clears");
    const job = {name: "morning", agent: "front", message: "go", schedule: "daily at 7:00", timezone: "UTC", conversation_id: "c1", delivery: "owner_inbox", condition: "paid"};
    same(Jobs.fromJob(job), Jobs.blank({name: "morning", mode: "fixed", conversation: "c1", kind: "agent", target: "front", message: "go",
      schedule: "daily at 7:00", timezone: "UTC", condition: "paid", delivery: "owner_inbox"}), "from a job");
    """)
  end

  test "the preview is asked for once a schedule, a zone and a target are given" do
    run!("""
    same(Jobs.previewOf({schedule: "daily at 7:00", timezone: "UTC", agent: "front"}),
      {schedule: "daily at 7:00", timezone: "UTC", target: {agent: "front"}}, "agent");
    same(Jobs.previewOf({schedule: "every 2h", timezone: "UTC", workflow: "review"}).target, {workflow: "review"}, "workflow");
    same(Jobs.previewOf({schedule: "", timezone: "UTC", agent: "front"}), null, "no schedule");
    same(Jobs.previewOf({schedule: "every 2h", timezone: "UTC"}), null, "no target");
    same(Jobs.previewOf(Jobs.formFields(Jobs.blank({kind: "workflow", target: "review", schedule: "every 2h", timezone: "UTC"}))).target, {workflow: "review"}, "from a form");
    """)
  end

  test "the estimate is a figure with its basis, or the no-history sentence" do
    run!("""
    same(Jobs.estimate({next: [], estimate_usd: 0.0312, basis: "from 8 recent runs of front"}), "About US$ 0.03 a fire, from 8 recent runs of front", "figure");
    same(Jobs.estimate({next: [], estimate_usd: null, basis: ""}), "No history for this target yet, so there is no estimate.", "none");
    same(Jobs.estimate({next: [], estimate_usd: null, basis: "front has not run yet"}), "front has not run yet", "its own words");
    same(Jobs.estimate(null), "", "before the answer");
    same(Jobs.nextFires({next: ["2026-11-14T07:00:00Z"]}, Date.parse("2026-11-13T12:00:00Z")).length, 1, "next fires");
    """)
  end

  test "a job's times carry the zone they are read in" do
    run!(
      """
      const now = Date.parse("2026-11-13T12:00:00Z");
      same(Jobs.at("2026-11-13T18:00:00Z", now), "Today 15:00 -03", "a fire");
      same(Jobs.nextFires({next: ["2026-11-14T18:00:00Z"]}, now), ["14 Nov 15:00 -03"], "next fires");
      same(Jobs.at(null, now), "—", "none");
      same(Time.zone("2026-11-13T18:00:00Z"), "-03", "the zone");
      """,
      [{"TZ", "America/Sao_Paulo"}]
    )

    run!(
      """
      same(Time.zone("2026-11-13T18:00:00Z"), "UTC", "no offset");
      """,
      [{"TZ", "UTC"}]
    )
  end

  test "a job's times read in the zone they are written in, whatever the viewer's" do
    run!(
      """
      const now = Date.parse("2026-11-13T12:00:00Z");
      same(Jobs.at("2026-11-13T18:00:00-05:00", now), "Today 18:00 -05", "written offset");
      same(Jobs.at("2026-11-13T18:00:00+05:30", now), "Today 18:00 +05:30", "half hours");
      same(Jobs.at("2026-11-13T18:00:00+00:00", now), "Today 18:00 UTC", "zero offset");
      same(Jobs.nextFires({next: ["2026-11-14T09:00:00+09:00", "2026-11-20T09:00:00+09:00"]}, now), ["14 Nov 09:00 +09", "20 Nov 09:00 +09"], "next fires");
      // 2026-11-13T02:00Z is the 12th at 23:00 in -03:00, and the 13th at 02:00 in UTC.
      same(Jobs.at("2026-11-12T10:00:00-03:00", Date.parse("2026-11-13T02:00:00Z")), "Today 10:00 -03", "day read in the offset");
      same(Jobs.at("2026-11-11T10:00:00-03:00", Date.parse("2026-11-13T02:00:00Z")), "Yesterday 10:00 -03", "yesterday in the offset");
      same(Jobs.at("2026-11-13T18:00:00Z", now), "Today 22:00 +04", "a Z stamp stays local");
      """,
      [{"TZ", "Asia/Dubai"}]
    )
  end

  test "a request proposes a job when its approve option creates one" do
    run!("""
    const create = {action: "create", name: "morning", agent: "front", schedule: "daily at 7:00", timezone: "UTC", message: "go"};
    const request = {reason: "Every day.\\n\\ncites 2 runs\\n\\njob morning as it would run:\\nruns: front\\nwhen: daily at 7:00 (UTC)\\n\\napprove creates it, edit sends back what to change, deny drops it",
      options: {approve: [{name: "jobs", args: create}], edit: [], deny: []}};
    same(Jobs.proposal(request), create, "the job");
    same(Jobs.reason(request), "Every day.\\n\\ncites 2 runs", "why");
    same(Jobs.proposal({options: {approve: [{name: "grant", args: {}}]}}), null, "a grant");
    same(Jobs.proposal({options: {grant: [], deny: []}}), null, "no approve");
    same(Jobs.proposal({}), null, "no options");
    same(Jobs.reason({reason: "plain"}), "plain", "plain reason");
    same(Jobs.proposes("seller", {name: "morning"}), "seller proposes a job: morning", "heading");
    """)
  end

  test "a proposal's lines say what the job sends, with the rest behind the toggle" do
    run!("""
    const job = {name: "morning", agent: "front", message: "go", schedule: "daily at 7:00", timezone: "UTC", delivery: "owner_inbox",
      condition: "paid", end_at: "2026-12-31T21:00:00.000Z", owner: agent("seller"), workspace: "site"};
    same(Jobs.lines(job).map(line => [line.name, line.value, line.detail]), [
      ["SENDS", "front is sent \\u201cgo\\u201d", false], ["ONLY WHEN", "paid passes", false],
      ["UNTIL", Jobs.endText("2026-12-31T21:00:00.000Z") + " " + Time.zone("2026-12-31T21:00:00.000Z"), false], ["DELIVERS", "each reply to the owner's inbox", false],
      ["RUNS AS", "seller", true], ["CHAT", "a new one each fire", true], ["WORKSPACE", "site", true]], "full");
    same(Jobs.lines({tool: "report", schedule: "every 2h"}).map(line => line.value), ["calls the tool report, with no model", "whoever approves it", "a new one each fire"], "a tool, no extras");
    same(Jobs.lines({workflow: "review", message: "x", conversation_id: "c1"})[0].value, "review workflow is sent \\u201cx\\u201d", "a workflow");
    """)
  end

  test "a proposal and its form ask the preview the same thing" do
    run!("""
    const created = {action: "create", name: "daily", agent: "front-desk", message: "Summarize", schedule: "daily at 18:00", timezone: "UTC", delivery: "owner_inbox"};
    const asked = JSON.stringify(Jobs.previewOf(created));
    same(asked, JSON.stringify(Jobs.previewOf(Jobs.formFields(Jobs.fromJob(created)))), "one request");
    same(asked, JSON.stringify({schedule: "daily at 18:00", timezone: "UTC", target: {agent: "front-desk"}}), "its target and schedule");
    """)
  end

  test "/job is the composer's shortcut to the form" do
    run!("""
    same(Jobs.command("/job"), "", "bare");
    same(Jobs.command("  /job every morning, summarize the news "), "every morning, summarize the news", "prefilled");
    same(Jobs.command("/jobs"), null, "another word");
    same(Jobs.command("write /job"), null, "not at the start");
    same(Jobs.command("hello"), null, "plain");
    same(Jobs.command("/JOB nightly"), "nightly", "any case");
    same(Jobs.commandHint("/job"), "Enter opens the job form", "said as soon as it is typed");
    same(Jobs.commandHint("/job every day"), "Enter opens the job form", "with its words");
    same(Jobs.commandHint("/jo"), "", "not yet");
    same(Jobs.commandHint("hello"), "", "plain text says nothing");
    """)
  end
end
