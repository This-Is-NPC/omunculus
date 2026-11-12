defmodule Omunculus.GuiPendingTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @modules ["Requests", "Questions", "Phrases", "Usage", "Time", "Progress", "Pending"]

  # A sale (w1, seller) handing a design down to a designer (w2), the front
  # agent being sales; times in seconds, stamps as the server's.
  @fixtures """
  const iso = t => new Date(t * 1000).toISOString();
  const human = {kind: "human", issuer: "local", subject: "1000"};
  const agent = name => ({kind: "agent", agent: name});
  const check = (ok, what, value) => { if (!ok) throw Error(what + " " + JSON.stringify(value)); };
  const sale = {name: "sale", steps: ["qualify", "design", "build"].map(name => ({name, agent: "seller"}))};
  const works = [
    {id: "w1", title: "Doce Ana: site", state: "waiting", waiting: "child", workflow: "sale", stage: "build", assignee: "seller", created_at: iso(1000), updated_at: iso(1200)},
    {id: "w2", title: "Build: Doce Ana", state: "open", parent_id: "w1", assignee: "surgeon", created_at: iso(1300), updated_at: iso(1400)}
  ];
  const lanes = {w1: Object.assign({at: 2}, sale), w2: null};
  const asked = (id, extra) => Object.assign({id, status: "pending", requester: agent("surgeon"), arbiter: human, work_id: "w2", reason: "", options: {}, origins: {}, created_at: iso(1500)}, extra);
  const grant = name => [{name: "grant", args: {kind: "resource", name}}];
  const permission = asked("p1", {reason: "I need to fetch fonts.", options: {grant: grant("sandbox.network"), grant_agent: grant("sandbox.network"), grant_stage: grant("sandbox.network"), grant_depth: grant("sandbox.network"), deny: [{name: "deny"}]}});
  const question = asked("q1", {reason: "Which WhatsApp number should the order button use?\\nIt goes on every page.", created_at: iso(1400)});
  const questions = asked("q2", {reason: "Before I start:\\n1. Which colours?\\n2. Which fonts?\\n3. Which number?", created_at: iso(1450)});
  const decision = asked("d1", {requester: agent("seller"), work_id: "w1", reason: "Ana asks for a fifth page.", options: {accept: [], keep: []}, created_at: iso(1600)});
  const run = (id, name, work) => ({id, agent: name, depth: 1, work_id: work, status: "open"});
  const build = (requests, runs, now) => Progress.build({me: human, works, lanes, journeys: {}, runs: runs || [], runStarts: {r1: 1900}, requests: requests || [], calling: {}, callArgs: {}, rootAgent: "sales", now: now || 2000});
  const out = build([permission, question, questions, decision], [run("r1", "surgeon", "w2")]);
  const input = request => ({me: human, flat: out.flat, front: "sales", noted: {}, folder: "/work/site", text: request.reason});
  """

  defp run!(assertions) do
    assert {"", 0} = GuiModules.run(@modules, @fixtures <> assertions)
  end

  test "the queue is what waits on you, oldest first, each climbing question once" do
    run!("""
    const agentAsks = asked("a1", {arbiter: agent("seller")});
    const gathering = asked("g1", {created_at: iso(1700), origins: {ask: asked("o1", {status: "escalated", created_at: iso(1100)})}});
    const review = asked("v1", {requester: agent("seller"), options: {approve: [], edit: [], deny: []}, interception: {action: "ask", summary: 'seller wants to ask local:1000: "Ready?"', step: 1, of: 2}, created_at: iso(1650)});
    const theirs = asked("t1", {arbiter: {kind: "human", issuer: "local", subject: "2000"}});
    const ids = Pending.queue([permission, agentAsks, decision, question, gathering, review, theirs], human).map(request => request.id).join();
    check(ids === "q1,p1,d1,v1,g1", "order, the viewer's requests, reviews included, origins hidden", ids);
    check(Pending.queue([], human).length === 0, "empty", "");
    """)
  end

  test "an item says who asks, the path down from the front desk, the work and what it unblocks" do
    run!("""
    const item = Pending.describe(permission, input(permission));
    check(item.kind === "permission" && item.word === "PERMISSION" && item.icon === "shield", "kind", item);
    check(item.asker === "surgeon" && item.path.join(" > ") === "sales > seller > surgeon", "path", item.path);
    check(item.work === "Build: Doce Ana", "work", item.work);
    check(item.title === "Surgeon asks to use the network", "title", item.title);
    check(item.grants === "use the network \\u00b7 this work only", "grants", item.grants);
    check(item.unblocks === "surgeon resumes Build: Doce Ana \\u00b7 sales and seller are waiting for it", "unblocks", item.unblocks);
    check(item.since === iso(1500), "since", item.since);
    const asks = Pending.describe(question, input(question));
    check(asks.kind === "needs-you" && asks.word === "QUESTION" && asks.icon === "help", "question kind", asks);
    check(asks.title === "Which WhatsApp number should the order button use?" && asks.body === "It goes on every page.", "title and body", asks);
    const long = Object.assign({}, question, {reason: "Approve the quote? It was priced at R$ 1,500. Ana decides alone.\\nMore."});
    const split = Pending.describe(long, input(long));
    check(split.title === "Approve the quote?" && split.body === "It was priced at R$ 1,500. Ana decides alone.\\n\\nMore.", "first sentence", split);
    const list = Pending.describe(questions, input(questions));
    check(list.title === "Surgeon asks 3 questions" && list.body === "" && list.asks === 3, "numbered list", list);
    const choose = Pending.describe(decision, input(decision));
    check(choose.word === "DECISION" && choose.icon === "diamond" && choose.path.join(" > ") === "sales > seller", "decision", choose);
    check(Pending.describe(Object.assign({}, decision, {arbiter: agent("seller")}), input(decision)).kind === "decision", "an agent's decision has its shape too", "");
    check(item.line === "from surgeon for you", "from whom, for whom", item.line);
    check(Pending.describe(Object.assign({}, question, {arbiter: agent("sales")}), input(question)).line === "from surgeon to sales", "to another account", "");
    const held = Object.assign({}, decision, {options: {approve: [], edit: [], deny: []}, interception: {action: "ask", summary: 'seller wants to ask local:1000: "Ready?"', step: 2, of: 3}});
    const review = Pending.describe(held, input(held));
    check(review.kind === "review" && review.word === "REVIEW" && review.title === 'Seller wants to ask local:1000: "Ready?"', "review", review);
    check(review.line === 'from seller for you \u00b7 step 2 of 3' && review.unblocks === "seller waits for your review", "review line", review.line);
    const parts = Pending.actions(Object.keys(held.options), false);
    check(parts.primary === "approve" && parts.once.join() === "approve,edit" && parts.denies.join() === "deny", "approve, edit, deny", parts);
    check(choose.unblocks === "seller resumes Doce Ana: site \\u00b7 sales is waiting for it", "single waiter", choose.unblocks);
    """)
  end

  test "a request from an unknown work falls back on the route it was passed along" do
    run!("""
    const lost = asked("x1", {work_id: "gone", reason: "Still there?"});
    const item = Pending.describe(lost, {flat: out.flat, front: "sales", noted: {}, folder: "", text: lost.reason});
    check(item.path.join(" > ") === "sales > surgeon" && item.work === "" && item.unblocks === "surgeon resumes its work \\u00b7 sales is waiting for it", "fallback", item);
    """)
  end

  test "actions group the options: given once, the no, and the scopes behind Always" do
    run!("""
    const all = Pending.actions(Object.keys(permission.options), true);
    check(all.once.join() === "grant" && all.denies.join() === "deny" && all.always.join() === "grant_agent,grant_stage", "permission", all);
    const pick = Pending.actions(["accept", "keep", "cancel"], false);
    check(pick.once.join() === "accept,keep" && pick.denies.join() === "cancel" && pick.always.length === 0, "decision", pick);
    check(all.primary === "grant" && pick.primary === "accept", "primary", [all.primary, pick.primary]);
    check(Pending.actions(["keep", "refuse"], false).primary === "keep" && Pending.actions(["approve", "deny"], false).primary === "approve", "keep fills, refuse never", 0);
    const fine = Pending.actions(["problem", "works", "changes", "hold"], false);
    check(fine.primary === "works", "the first that is not deny-like fills", fine);
    check(Pending.actions(["problem", "adjust", "hold"], false).primary === "", "never a deny-like option", 0);
    check(Pending.actions(["use_it", "cancel"], false).primary === "use_it" && Requests.negative("grant_stage") === false, "words", 0);
    """)
  end

  test "an option reads whole even when its scope names nothing" do
    run!("""
    const labels = ["grant", "grant_agent", "grant_stage", "grant_depth", "grant_workspace", "deny"].map(option => Requests.optionLabel(option));
    check(labels.join("|") === "GRANT\\u00a0\\u00b7\\u00a0THIS WORK ONLY|FOR THIS AGENT|IN THIS STAGE|AT THIS DEPTH|IN THE PROJECT|DENY", "bare", labels);
    check(Requests.optionLabel("grant_stage", {stage: "build"}) === "IN THE BUILD STAGE", "stage", "");
    check(Requests.optionLabel("grant_workspace", {folder: "site"}) === "IN FOLDER site", "folder", "");
    """)
  end

  test "what you did to a request is one sentence with its kind's icon and word" do
    run!("""
    const said = (request, reply) => Pending.resolved(request, reply, input(request));
    const granted = said(permission, {option: "grant"});
    check(granted.word === "GRANTED" && granted.icon === "shield" && granted.sentence === "You granted surgeon permission to use the network (Build: Doce Ana)", "granted", granted);
    check(said(permission, {option: "grant_agent"}).sentence.includes("\\u00b7 for surgeon (Build"), "scope", said(permission, {option: "grant_agent"}));
    const denied = said(permission, {option: "deny"});
    check(denied.word === "DENIED" && denied.icon === "close" && denied.sentence.startsWith("You denied surgeon permission"), "denied", denied);
    const chose = said(decision, {option: "accept"});
    check(chose.word === "CHOSE" && chose.icon === "diamond" && chose.sentence === "You chose accept on seller's decision (Doce Ana: site)", "chose", chose);
    const held = Object.assign({}, decision, {options: {approve: [], edit: [], deny: []}, interception: {action: "ask", summary: 'seller wants to ask local:1000: "Ready?"', step: 1, of: 1}});
    check(said(held, {option: "approve"}).sentence === "You approved: seller wants to ask local:1000: \\"Ready?\\" (Doce Ana: site)" && said(held, {option: "edit"}).word === "EDITED" && said(held, {option: "deny"}).word === "DENIED", "review", said(held, {option: "edit"}));
    check(said(decision, {option: "adjust"}).sentence === "You asked seller to adjust (Doce Ana: site)", "adjust", "");
    const answered = said(question, {option: "", body: "5511"});
    check(answered.word === "ANSWERED" && answered.icon === "help" && answered.sentence === "You answered surgeon's question (Build: Doce Ana)", "answered", answered);
    check(said(questions, {body: "1. a"}).sentence === "You answered surgeon's 3 questions (Build: Doce Ana)", "list", "");
    const sales = asked("s1", {requester: agent("sales"), work_id: "", reason: "Colours?"});
    check(Pending.resolved(sales, {body: "x"}, {flat: out.flat, text: "Colours?"}).sentence === "You answered sales' question", "possessive of a name in s", "");
    """)
  end

  test "a request shows in the chat by whom it is for and whether it waits" do
    run!("""
    const contained = new Set();
    const place = (request, over) => Pending.place(request, Object.assign({me: human, contained}, over));
    check(place(question) === "ask" && place(permission) === "ask" && place(decision) === "ask", "waiting for you is answered in place", "");
    const answered = Object.assign({}, question, {status: "answered"});
    check(place(answered) === "history", "settled for you is history", "");
    const agentAsks = asked("a1", {arbiter: agent("seller")});
    check(place(agentAsks) === "team" && place(Object.assign({}, agentAsks, {status: "answered"})) === "team", "between agents is a compact line, waiting or not", "");
    check(place(asked("t1", {arbiter: {kind: "human", issuer: "local", subject: "2000"}})) === "team", "another person's is not yours", "");
    check(place(question, {contained: new Set(["q1"])}) === "none" && place(undefined) === "none", "gathered or unread shows nothing", "");
    // In time order, each request keeps its place whatever its state.
    const between = Object.assign({}, agentAsks, {created_at: iso(1550)});
    const entries = [decision, between, answered, permission].sort((a, b) => a.created_at.localeCompare(b.created_at));
    const shown = entries.map(request => request.id + ":" + place(request)).join();
    check(shown === "q1:history,p1:ask,a1:team,d1:ask", "order", shown);
    """)
  end

  test "a card in the chat starts collapsed unless it is the newest waiting on you" do
    run!("""
    const requests = [question, questions, permission, decision];
    const collapsed = request => Pending.startsCollapsed(request, requests, human);
    check(!collapsed(decision), "the newest waiting is expanded", "");
    check(collapsed(permission) && collapsed(question) && collapsed(questions), "older waiting ones are collapsed", "");
    const answered = requests.map(request => request.id === "d1" ? Object.assign({}, request, {status: "answered"}) : request);
    check(Pending.startsCollapsed(decision, answered, human), "an answered one is collapsed", "");
    check(!Pending.startsCollapsed(permission, answered, human), "the newest still waiting takes over", "");
    check(Pending.startsCollapsed(asked("a1", {arbiter: agent("seller")}), requests, human), "one not for you is collapsed", "");
    """)
  end
end
