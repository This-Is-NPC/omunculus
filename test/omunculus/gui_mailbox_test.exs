defmodule Omunculus.GuiMailboxTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @fixtures """
  const me = {issuer: "local", subject: "1000"};
  const human = {kind: "human", issuer: "local", subject: "1000"};
  const agent = name => ({kind: "agent", agent: name});
  const prompt = (cursor, at, message, to) => ({type: "prompt", cursor, at, actor: human, body: {message, agent: to || "sales"}});
  const run = (id, who, status, depth) => ({id, agent: who, depth: depth === undefined ? 0 : depth, status, started_at: "2026-01-01T10:00:00Z", finished_at: status === "open" ? null : "2026-01-01T10:05:00Z"});
  const comment = (cursor, at, run_id, work_id, text) => ({type: "comment", cursor, at, run_id, work_id, body: {body: text}});
  const model = (cursor, at, run_id, text) => ({type: "model", cursor, at, run_id, body: {content: text}});
  const request = (id, over) => Object.assign({id, status: "pending", requester: agent("sales"), arbiter: human, reason: "Which pages?", origins: {}, options: {}, created_at: "2026-01-01T10:02:00Z"}, over || {});
  const snap = over => Object.assign({conversation: {created_at: "2026-01-01T09:00:00Z"}, works: [{id: "w1", parent_id: null, state: "done"}], runs: [], requests: []}, over || {});
  const build = (snapshot, events) => Mailbox.build("agency", "c1", snapshot, events, me);
  """

  defp run!(assertions) do
    assert {"", 0} =
             GuiModules.run(["Requests", "Model", "Jobs", "Mailbox"], @fixtures <> assertions)
  end

  test "the client scripts avoid String.trimEnd, which the QML engine lacks" do
    for file <- Path.wildcard("apps/kit/client/*.js") ++ Path.wildcard("apps/*/*.{js,qml}") do
      refute File.read!(file) =~ ~r/\.trim(End|Start)\(/, file
    end
  end

  test "addresses, names and autocomplete" do
    run!("""
    const p = Mailbox.person("sales", "agency");
    if (p.text !== "Sales <sales@agency>") throw Error(p.text);
    if (Mailbox.person("language_lawyer", "x").name !== "Language lawyer") throw Error("name");
    const roster = [{name: "sales", depth: 0}, {name: "seller", depth: 1}, {name: "flow", depth: 0, workflow_only: true}];
    if (Mailbox.chat(roster).join() !== "sales") throw Error("only depth 0 and not workflow-only");
    const list = Mailbox.recipients([{id: "agency", agents: ["sales", "steward"]}, {id: "dev", agents: ["sales"]}]);
    if (list.length !== 3) throw Error("across projects");
    if (Mailbox.suggest(list, "ste").map(x => x.address).join() !== "steward@agency") throw Error("suggest by name");
    if (Mailbox.suggest(list, "@dev").map(x => x.address).join() !== "sales@dev") throw Error("suggest by address");
    if (Mailbox.suggest(list, "").length !== 3) throw Error("empty query lists all");
    if (Mailbox.suggest(list, "SALES").length !== 2) throw Error("case aside, by name");
    const places = [
      {id: "dev", agents: ["a", "b"], defaultAgent: ""},
      {id: "agency", agents: ["auditor", "sales", "steward"], defaultAgent: "sales"},
      {id: "locked", agents: ["x"], defaultAgent: "", canWrite: false}
    ];
    const order = Mailbox.recipients(places, "agency").map(x => x.address).join();
    if (order !== "sales@agency,auditor@agency,steward@agency,a@dev,b@dev") throw Error(order);
    if (Mailbox.recipients(places, "")[0].address !== "a@dev") throw Error("no current project keeps registry order");
    if (!Mailbox.canWrite(["conversation.create", "conversation.send"]) || Mailbox.canWrite(["conversation.send"]) || Mailbox.canWrite([])) throw Error("capabilities");
    """)
  end

  test "the type-ahead lists nothing until something is typed, then filters by name or address" do
    run!("""
    const list = Mailbox.recipients([{id: "agency", agents: ["sales", "steward"]}, {id: "dev", agents: ["sales"]}]);
    if (Mailbox.complete(list, "", []).length !== 0) throw Error("empty shows nothing");
    if (Mailbox.complete(list, "   ", []).length !== 0) throw Error("blank shows nothing");
    if (Mailbox.complete(list, "ste", []).map(x => x.address).join() !== "steward@agency") throw Error("by name");
    if (Mailbox.complete(list, "@dev", []).map(x => x.address).join() !== "sales@dev") throw Error("by address");
    if (Mailbox.complete(list, "sales", ["sales@agency"]).map(x => x.address).join() !== "sales@dev") throw Error("not twice");
    if (Mailbox.complete(list, "zzz", []).length !== 0) throw Error("no match");
    """)
  end

  test "a reply is prefilled to the other party, Reply all to every counterpart" do
    run!("""
    const events = [
      prompt("1", "2026-01-01T10:00:00Z", "Website\\n\\nI need a site."),
      comment("2", "2026-01-01T10:01:00Z", "r1", "w1", "Thanks.")
    ];
    const one = build(snap({runs: [run("r1", "sales", "closed")]}), events);
    if (Mailbox.counterparts(one).map(x => x.address).join() !== "sales@agency") throw Error("one counterpart");
    if (Mailbox.canReplyAll(one)) throw Error("a thread with one counterpart has no Reply all");
    const theirs = one.messages.find(m => !m.mine);
    if (Mailbox.replyRecipients(one, theirs, false).map(x => x.address).join() !== "sales@agency") throw Error("to the sender");
    const mine = one.messages.find(m => m.mine);
    if (Mailbox.replyRecipients(one, mine, false).map(x => x.address).join() !== "sales@agency") throw Error("to whom I wrote");
    const two = build(snap({runs: [run("r1", "sales", "closed")], requests: [request("q1", {requester: agent("seller")})]}), events);
    const all = Mailbox.counterparts(two).map(x => x.address).join();
    if (all !== "sales@agency,seller@agency") throw Error(all);
    if (!Mailbox.canReplyAll(two)) throw Error("several counterparts");
    const ask = two.messages.find(m => m.request === "q1");
    if (Mailbox.replyRecipients(two, ask, false).map(x => x.address).join() !== "seller@agency") throw Error("only the asker");
    if (Mailbox.replyRecipients(two, ask, true).length !== 2) throw Error("everyone");
    """)
  end

  test "an empty To sends without an agent, and its hint names the default agent" do
    run!("""
    const front = Mailbox.person("front-desk", "agency");
    const desk = Mailbox.hint(front);
    if (desk !== "to Front desk if left empty") throw Error(desk);
    if (Mailbox.hint(null) !== "name or address") throw Error("no default");
    const empty = Mailbox.sendTarget(null, front);
    if (empty.project !== "agency" || empty.agent !== "") throw Error("empty To: " + JSON.stringify(empty));
    const named = Mailbox.sendTarget(Mailbox.person("steward", "agency"), front);
    if (named.agent !== "steward") throw Error("a chosen account wins");
    if (Mailbox.sendTarget(null, null) !== null) throw Error("nowhere to send");
    """)
  end

  test "the folded rail counts the e-mails and the unread ones" do
    run!("""
    const threads = [{key: "a", heard: "2026-01-01T10:00:00Z"}, {key: "b", heard: ""}, {key: "c", heard: "2026-01-02T10:00:00Z"}];
    const seen = {a: "2026-01-01T10:00:00Z"};
    const count = Mailbox.railCount(threads, seen);
    if (count.total !== 3 || count.unread !== 1) throw Error(JSON.stringify(count));
    if (Mailbox.railCount([], {}).total !== 0) throw Error("empty");
    """)
  end

  test "the default agent comes from the whole config and must be one to write to" do
    run!("""
    const roster = [{name: "sales", depth: 0}, {name: "seller", depth: 1}];
    const setup = name => ({agents: roster, default_agent: name === undefined ? null : name});
    if (Mailbox.defaultAgent(setup("sales")) !== "sales") throw Error("declared");
    if (Mailbox.defaultAgent(setup()) !== "") throw Error("absent");
    if (Mailbox.defaultAgent(setup("seller")) !== "") throw Error("not depth 0");
    if (Mailbox.defaultAgent({agents: roster}) !== "") throw Error("missing key");
    """)
  end

  test "a thread is the person's messages, the agent's words and its requests for the person" do
    run!("""
    const events = [
      prompt("1", "2026-01-01T10:00:00Z", "Website\\n\\nI need a site."),
      comment("2", "2026-01-01T10:01:00Z", "r1", "w1", "Thanks, one question coming."),
      {type: "model", cursor: "3", at: "2026-01-01T10:01:30Z", run_id: "r1", body: {content: [{type: "text", text: "I will ask now"}, {type: "tool_use", name: "ask", input: {}}]}},
      comment("4", "2026-01-01T10:01:40Z", "r2", "w1", "I am the seller talking to myself"),
      model("6", "2026-01-01T10:01:50Z", "r1", "Ana accepted; I told the team."),
      comment("7", "2026-01-01T10:01:55Z", "r1", "w2", "A note on a child work"),
      {type: "reply", cursor: "5", at: "2026-01-01T10:03:00Z", request_id: "q1", actor: human, body: {body: "Home and Menu"}}
    ];
    const snapshot = snap({
      runs: [run("r1", "sales", "closed"), run("r2", "seller", "closed", 1)],
      works: [{id: "w1", parent_id: null, state: "done"}, {id: "w2", parent_id: "w1", state: "done"}],
      requests: [
        request("q1", {status: "closed"}),
        request("q2", {created_at: "2026-01-01T10:04:00Z", reason: "Which colour?"}),
        request("q3", {requester: agent("seller"), reason: "owner approval"}),
        request("q4", {arbiter: agent("sales")})
      ]
    });
    const t = build(snapshot, events);
    if (t.agent !== "sales" || t.with.text !== "Sales <sales@agency>") throw Error("agent");
    if (t.subject !== "Website") throw Error("subject " + t.subject);
    const shown = t.messages.filter(m => m.request !== "q3").map(m => (m.mine ? "me:" : "sales:") + m.text);
    const want = ["me:I need a site.", "sales:Thanks, one question coming.", "sales:Which pages?", "me:Home and Menu", "sales:Which colour?"];
    if (JSON.stringify(shown) !== JSON.stringify(want)) throw Error(JSON.stringify(shown));
    if (t.messages.some(m => m.text.includes("seller"))) throw Error("another agent's comment leaked");
    const owner = t.messages.find(m => m.request === "q3");
    if (!owner || owner.from.address !== "seller@agency" || owner.text !== "owner approval" || !t.pending.includes("q3")) throw Error("a question to the viewer from another agent is mail, from that agent");
    if (t.messages.some(m => m.request === "q4")) throw Error("a question to another account is not mail");
    if (t.received !== 4 || t.sent !== 2) throw Error("counts");
    if (t.pending.join() !== "q3,q2") throw Error("pending " + t.pending);
    """)
  end

  test "plain model text never reaches the mailbox, and a file shows on its own run's e-mail" do
    run!("""
    const works = [{id: "w1", parent_id: null, state: "waiting"}];
    const attach = (cursor, at, run_id, name) => ({type: "attach", cursor, at, run_id, body: {attachments: [{name, sha256: "x" + cursor}], note: "doc version 1"}});
    const hi = prompt("1", "2026-01-01T10:00:00Z", "Hi");
    const alone = build(snap({runs: [run("r1", "sales", "closed")], works}), [hi, model("2", "2026-01-01T10:01:00Z", "r1", "Ana accepted the proposal.")]);
    if (alone.messages.length !== 1 || alone.received !== 0) throw Error("model text is no e-mail");
    const asked = build(snap({runs: [run("r1", "sales", "closed")], works, requests: [request("q1", {run_id: "r1", reason: "Do you accept?"})]}),
      [hi, attach("2", "2026-01-01T10:01:00Z", "r1", "Proposal.md")]);
    const mail = asked.messages.find(m => m.request === "q1");
    if (asked.messages.length !== 2 || mail.files.map(f => f.name).join() !== "Proposal.md" || mail.text !== "Do you accept?") throw Error(JSON.stringify(asked.messages));
    const said = build(snap({runs: [run("r1", "sales", "closed")], works}),
      [hi, attach("2", "2026-01-01T10:01:00Z", "r1", "Proposal.md"), comment("3", "2026-01-01T10:02:00Z", "r1", "w1", "Here it is.")]);
    const one = said.messages[1];
    if (said.messages.length !== 2 || one.text !== "Here it is." || one.files.length !== 1) throw Error(JSON.stringify(said.messages));
    const bare = build(snap({runs: [run("r1", "sales", "closed")], works}), [hi, attach("2", "2026-01-01T10:01:00Z", "r1", "Proposal.md")]);
    if (bare.messages[1].text !== "" || bare.messages[1].files.length !== 1 || bare.snippet !== "[Proposal.md]") throw Error(JSON.stringify(bare.messages) + bare.snippet);
    """)
  end

  test "a request's e-mail is only the thread agent's reason, never its origins' questions" do
    run!("""
    const origins = {seller: {reason: "The status is sent, awaiting you"}, price: {reason: "Which pages?"}};
    const t = build(snap({requests: [request("q1", {origins})]}), [prompt("1", "2026-01-01T10:00:00Z", "Hi")]);
    const text = t.messages.find(m => m.request === "q1").text;
    if (text !== "Which pages?") throw Error(JSON.stringify(text));
    const longer = build(snap({requests: [request("q1", {reason: "Proposal ready.", origins: {a: {reason: "Proposal ready. Status is sent."}}})]}), [prompt("1", "2026-01-01T10:00:00Z", "Hi")]);
    if (longer.messages.find(m => m.request === "q1").text !== "Proposal ready.") throw Error("an origin's text is not the body");
    """)
  end

  test "harness notes stay hidden and passed-on questions show as the agent's" do
    run!("""
    const harness = id => ({type: "request", cursor: "h" + id, at: "2026-01-01T10:02:00Z", request_id: id, actor: {kind: "harness"}, body: {}});
    const events = [prompt("1", "2026-01-01T10:00:00Z", "Hi"), harness("n1"), harness("n2")];
    const snapshot = snap({requests: [
      request("n1", {requester: agent("seller"), reason: "left unanswered", origins: {}}),
      request("n2", {requester: agent("seller"), reason: "it came to you", origins: {ask: {reason: "What is the budget?"}}})
    ]});
    const t = build(snapshot, events);
    if (t.messages.some(m => m.request === "n1")) throw Error("a note between agents is no e-mail");
    if (t.pending.join() !== "n2") throw Error("pending " + t.pending);
    const text = t.messages.find(m => m.request === "n2").text;
    if (text !== "What is the budget?") throw Error(text);
    """)
  end

  test "the first message splits into subject and body" do
    run!("""
    const s = Mailbox.split("Menu photos\\n\\nWhich ones?");
    if (s.subject !== "Menu photos" || s.body !== "Which ones?") throw Error("split");
    const one = Mailbox.split("I accept.");
    if (one.subject !== "I accept." || one.body !== "I accept.") throw Error("one line is its own body");
    const long = Mailbox.split("x".repeat(120) + "\\nrest");
    if (long.subject.length !== 90 || !long.body.startsWith("xxx")) throw Error("long first line");
    if (Mailbox.re("Menu") !== "Re: Menu" || Mailbox.re("re: Menu") !== "re: Menu") throw Error("re");
    if (Mailbox.fwd("Menu") !== "Fwd: Menu") throw Error("fwd");
    const q = Mailbox.quoted({from: {name: "Sales"}, text: "a\\n\\nb"}, "10 Nov 2026, 18:02");
    if (q.head !== "On 10 Nov 2026, 18:02, Sales wrote:" || q.lines.join("|") !== "> a|>|> b") throw Error(JSON.stringify(q));
    const w = Mailbox.quoted({from: {name: "Sales"}, text: "a  \\nb\\t"}, "x");
    if (w.lines.join("|") !== "> a|> b") throw Error("trailing blanks: " + JSON.stringify(w));
    """)
  end

  test "a subject sent apart is the thread's, with the body whole; the files of an answer show on it" do
    run!("""
    const file = {name: "brief.pdf", media_type: "application/pdf", bytes: 4, sha256: "ab"};
    const first = {type: "prompt", cursor: "1", at: "2026-01-01T10:00:00Z", actor: human, body: {message: "pra minha loja\\nmais uma linha", subject: "eu quero um site", agent: "sales"}};
    const events = [first, {type: "reply", cursor: "2", at: "2026-01-01T10:03:00Z", request_id: "q1", actor: human, body: {body: "see it", attachments: [file]}}];
    const t = build(snap({runs: [run("r1", "sales", "closed")], requests: [request("q1", {status: "closed"})]}), events);
    if (t.subject !== "eu quero um site") throw Error("subject " + t.subject);
    const mine = t.messages.filter(m => m.mine);
    if (mine[0].text !== "pra minha loja\\nmais uma linha") throw Error("the body stays whole: " + mine[0].text);
    if (mine[1].files.length !== 1 || mine[1].files[0].name !== "brief.pdf") throw Error("answer files " + JSON.stringify(mine[1].files));
    const plain = build(snap({runs: [run("r1", "sales", "closed")]}), [prompt("1", "2026-01-01T10:00:00Z", "Website\\n\\nI need a site.")]);
    if (plain.subject !== "Website") throw Error("a message without a subject keeps its first line");
    """)
  end

  test "mail holds the requests whose arbiter is the person, never reviews" do
    run!("""
    const events = [prompt("1", "2026-01-01T10:00:00Z", "Hi")];
    const works = [{id: "w1", state: "waiting", waiting: "request", parent_id: null}];
    const closed = [run("r1", "sales", "closed")];
    const mails = (requests) => build(snap({runs: closed, works, requests}), events);
    const other = {kind: "human", issuer: "local", subject: "2000"};
    const held = {action: "ask", summary: 'ask local:1000: "Ready?"', step: 1, of: 1};
    const options = {approve: [], edit: [], deny: []};
    const shown = mails([request("c"), request("o1", {arbiter: other}), request("o2", {arbiter: agent("seller")}),
      request("v1", {reason: "Sales would ask local:1000", options, interception: held}),
      request("v2", {reason: "Sales would ask local:2000", options, interception: held, arbiter: other})]);
    if (shown.pending.join() !== "c") throw Error("pending " + shown.pending);
    if (shown.messages.some(message => ["o1", "o2", "v1", "v2"].includes(message.request))) throw Error("only questions addressed to the person are mail");
    const hidden = mails([request("o1", {arbiter: other})]);
    if (hidden.pending.length !== 0 || hidden.label !== "progress") throw Error("only others' requests: " + hidden.label);
    const only = mails([request("v1", {options, interception: held})]);
    if (only.messages.length !== 1 || only.received !== 0 || Mailbox.inFolder(only, "inbox", {})) throw Error("a review alone is no inbox mail");
    if (only.label !== "") throw Error("a review waiting for the person reads as waiting: " + only.label);
    if (JSON.stringify(Mailbox.answer(" Go ")) !== JSON.stringify({body: "Go"})) throw Error("an answer is words only");
    """)
  end

  test "pending lists the reviews whose arbiter is the person, newest first" do
    run!("""
    const events = [prompt("1", "2026-01-01T10:00:00Z", "Hi")];
    const other = {kind: "human", issuer: "local", subject: "2000"};
    const held = (summary, step, of, args) => ({action: "ask", summary, step, of, args: args || []});
    const options = {approve: [], edit: [], deny: []};
    const t = build(snap({runs: [run("r1", "sales", "closed")], requests: [
      request("c"),
      request("v1", {requester: agent("seller"), reason: "Seller would ask", options, interception: held('seller wants to ask local:1000: "Ready?"', 1, 2), created_at: "2026-01-01T10:03:00Z"}),
      request("v2", {options, interception: held('sales wants to comment: "Done"', 1, 1), created_at: "2026-01-01T10:04:00Z"}),
      request("v3", {options, interception: held("sales wants to run x", 1, 1, [{name: "to", value: "prod"}]), arbiter: other}),
      request("v4", {options, interception: held("tool y", 1, 1), status: "answered"})
    ]}), events);
    if (t.reviews.map(review => review.request).join() !== "v1,v2") throw Error("only pending reviews for the person: " + t.reviews.map(review => review.request));
    const first = t.reviews[0];
    if (first.from.address !== "seller@agency" || first.text !== "Ready?" || first.summary !== 'Seller wants to ask local:1000: "Ready?"' || "step" in first || "of" in first || first.key !== "agency/c1/v1") throw Error(JSON.stringify(first));
    if (first.outcome !== "If you approve: Seller goes ahead as written. Edit changes its text. Deny tells Seller no.") throw Error(first.outcome);
    const tool = build(snap({runs: [run("r1", "sales", "closed")], requests: [request("v9", {options, interception: held("sales wants to run promote", 1, 1, [{name: "to", value: "prod"}])})]}), events).reviews[0];
    if (tool.args.length !== 1 || tool.args[0].value !== "prod" || tool.text !== "" || !tool.outcome.includes("Edit approves with your note")) throw Error(JSON.stringify(tool));
    if (t.reviews[1].from.name !== "Sales" || build(snap(), events).reviews.length !== 0) throw Error("none without reviews");
    const all = [first, t.reviews[1]];
    if (Mailbox.reviewMatches(first, "ready") !== true || Mailbox.reviewMatches(first, "zebra") !== false || all.filter(review => Mailbox.reviewMatches(review, "seller")).length !== 1) throw Error("search");
    if (Mailbox.inFolder(t, "pending", {})) throw Error("pending holds reviews, not threads");
    """)
  end

  test "an answer to a review is mail you sent, in Sent, with the words that went with it" do
    run!("""
    const events = [prompt("1", "2026-01-01T10:00:00Z", "Hi"),
      {type: "reply", cursor: "9", at: "2026-01-01T10:06:00Z", request_id: "v1", actor: human, body: {body: "Not yet", option: "deny"}},
      {type: "reply", cursor: "8", at: "2026-01-01T10:05:00Z", request_id: "v2", actor: human, body: {body: "approve", option: "approve"}}];
    const options = {approve: [], edit: [], deny: []};
    const held = summary => ({action: "tool", summary, step: 1, of: 1, args: []});
    const t = build(snap({runs: [run("r1", "sales", "closed")], requests: [
      request("v1", {status: "closed", options, interception: held("sales wants to run promote")}),
      request("v2", {status: "closed", options, interception: held("sales wants to run deploy")})
    ]}), events);
    const sent = t.messages.filter(message => message.mine && message.request !== "");
    if (sent.map(message => message.text).join("|") !== "Approved: Sales wants to run deploy|Denied: Sales wants to run promote\\n\\nNot yet") throw Error(JSON.stringify(sent.map(message => message.text)));
    if (t.reviews.length !== 0 || !Mailbox.inFolder(t, "sent", {}) || sent[0].to.address !== "sales@agency") throw Error("it is in Sent");
    if (Mailbox.decided.approve !== "Approved" || Mailbox.decided.edit !== "Edited" || Mailbox.decided.deny !== "Denied") throw Error("words");
    """)
  end

  test "a thread's parties name every sender, the agent first, then me" do
    run!("""
    const events = [prompt("1", "2026-01-01T10:00:00Z", "Hi")];
    const t = build(snap({runs: [run("r1", "sales", "closed")], requests: [request("q1", {requester: agent("seller")})]}), events);
    if (t.parties !== "Sales, Seller, me (2)") throw Error(t.parties);
    if (build(snap({runs: [run("r1", "sales", "closed")]}), events).parties !== "Sales, me") throw Error("alone");
    """)
  end

  test "a decision on a review sends approve, the edited words or the reason to deny" do
    run!("""
    if (JSON.stringify(Mailbox.decision("approve", "")) !== JSON.stringify({body: "approve", option: "approve"})) throw Error("approve");
    if (JSON.stringify(Mailbox.decision("edit", "  Better words ")) !== JSON.stringify({body: "Better words", option: "edit"})) throw Error("edit");
    if (JSON.stringify(Mailbox.decision("deny", "Too early")) !== JSON.stringify({body: "Too early", option: "deny"})) throw Error("deny with a reason");
    if (JSON.stringify(Mailbox.decision("deny", "")) !== JSON.stringify({body: "deny", option: "deny"})) throw Error("deny without one");
    """)
  end

  test "labels: in progress, stuck, cancelled, or none" do
    run!("""
    const at = "2026-01-01T10:00:00Z";
    const events = [prompt("1", at, "Hi")];
    const label = (over, ev) => build(snap(over), ev || events).label;
    const work = (state, waiting, parent) => ({id: "w" + Math.random(), state, waiting: waiting || null, parent_id: parent || null});
    if (label({runs: [run("r1", "sales", "open")], works: [work("open")]}) !== "progress") throw Error("run open");
    if (label({runs: [run("r1", "sales", "open", 2)]}) !== "progress") throw Error("any depth");
    if (label({runs: [run("r1", "sales", "closed")], works: [work("waiting", "child"), work("open", null, "x")]}) !== "progress") throw Error("work waits on children");
    if (label({runs: [run("r1", "sales", "closed")], works: [work("open")], requests: [request("q9", {arbiter: agent("sales"), requester: agent("seller")})]}) !== "progress") throw Error("waits on someone else");
    if (label({runs: [run("r1", "sales", "closed")], works: [work("open")]}) !== "stuck") throw Error("stalled");
    const failed = [prompt("1", at, "Hi"), {type: "end-run", cursor: "9", at, run_id: "r1", body: {error: "boom"}}];
    if (label({runs: [run("r1", "sales", "closed")], works: [work("done")]}, failed) !== "stuck") throw Error("failed");
    if (label({runs: [run("r1", "sales", "closed")], works: [work("cancelled"), work("cancelled")]}) !== "cancelled") throw Error("cancelled");
    if (label({runs: [run("r1", "sales", "closed")], works: [work("done")]}) !== "") throw Error("done has no label");
    if (label({runs: [run("r1", "sales", "closed")], works: [work("open")], requests: [request("q1")]}) !== "") throw Error("waiting for the client is no label");
    if (label({runs: [run("r1", "sales", "closed")], works: [work("waiting", "message")]}) !== "") throw Error("waiting for the client's word is no label");
    if (Mailbox.labels.stuck !== "Stuck") throw Error("words");
    """)
  end

  test "a reply answers the request of the e-mail it replies to, else the newest, else messages the agent" do
    run!("""
    const events = [prompt("1", "2026-01-01T10:00:00Z", "Hi"), comment("2", "2026-01-01T10:01:00Z", "r1", "w1", "Hello")];
    const two = build(snap({runs: [run("r1", "sales", "closed")], requests: [
      request("q1", {created_at: "2026-01-01T10:02:00Z", reason: "First?"}),
      request("q2", {created_at: "2026-01-01T10:03:00Z", reason: "Second?"})
    ]}), events);
    if (two.pending.join() !== "q1,q2") throw Error("pending order");
    let t = Mailbox.replyTarget(two, "q1");
    if (t.request !== "q1" || t.quoted.text !== "First?") throw Error("replying to a request answers it");
    t = Mailbox.replyTarget(two, "r1");
    if (t.request !== "q2" || t.quoted.text !== "Second?") throw Error("an ordinary e-mail answers the newest pending request, and quotes it");
    const none = build(snap({runs: [run("r1", "sales", "closed")]}), events);
    t = Mailbox.replyTarget(none, "r1");
    if (t.request !== "" || t.quoted.text !== "Hello") throw Error("no request: a message to the agent");
    if (JSON.stringify(Mailbox.answer("  yes ")) !== JSON.stringify({body: "yes"})) throw Error("text only");
    const closed = build(snap({runs: [run("r1", "sales", "closed")], requests: [request("q1", {status: "closed"})]}), events);
    if (Mailbox.replyTarget(closed, "q1").request !== "") throw Error("a closed request is not answered");
    """)
  end

  test "folders, archive, unread, search and forward" do
    run!("""
    const events = [prompt("1", "2026-01-01T10:00:00Z", "Hi\\n\\nabout the menu"), comment("2", "2026-01-01T10:01:00Z", "r1", "w1", "Hello")];
    const t = build(snap({runs: [run("r1", "sales", "closed")]}), events);
    const lone = build(snap(), [events[0]]);
    const none = {};
    if (!Mailbox.inFolder(t, "inbox", none) || !Mailbox.inFolder(t, "sent", none)) throw Error("both");
    if (Mailbox.inFolder(lone, "inbox", none) || !Mailbox.inFolder(lone, "sent", none)) throw Error("unanswered is only sent");
    const archived = {[t.key]: "2026-01-01T11:00:00Z"};
    if (Mailbox.inFolder(t, "inbox", archived) || !Mailbox.inFolder(t, "archive", archived)) throw Error("archived");
    const later = {[t.key]: "2026-01-01T10:00:30Z"};
    if (!Mailbox.inFolder(t, "inbox", later) || Mailbox.inFolder(t, "archive", later)) throw Error("new mail unarchives");
    if (Mailbox.inFolder(t, "drafts", none)) throw Error("drafts hold no threads");
    if (!Mailbox.isUnread(t, none) || Mailbox.isUnread(t, {[t.key]: t.heard}) || Mailbox.isUnread(lone, none)) throw Error("unread");
    if (!Mailbox.matches(t, "MENU") || !Mailbox.matches(t, "agency") || Mailbox.matches(t, "zzz")) throw Error("search");
    const f = Mailbox.forward(t, t.messages[1]);
    if (f.subject !== "Fwd: Hi" || !f.body.includes("From: Sales <sales@agency>") || !f.body.endsWith("Hello")) throw Error(f.body);
    """)
  end

  test "a job's messages are one thread each, from <name> <no-reply · job>, unread as the API says" do
    run!("""
    const msg = (id, job, name, at, text, unread) => ({id, job_id: job, sender: {kind: "job", name}, at, text, conversation_id: "c" + id, run_ids: [], unread});
    const threads = Mailbox.jobThreads("agency", [
      msg("f2", "j1", "news", "2026-01-02T07:00:00Z", "Day two", true),
      msg("f1", "j1", "news", "2026-01-01T07:00:00Z", "Day one", false),
      msg("g1", "j2", "report", "2026-01-01T09:00:00Z", "Weekly", false)
    ], [{id: "j1", name: "news", agent: "sales"}, {id: "j2", name: "report", workflow: "flow"}]);
    if (threads.length !== 2) throw Error("one thread per job");
    const t = threads[0];
    if (t.key !== "agency/job:j1" || t.subject !== "news" || t.label !== "job" || t.agent !== "sales") throw Error(JSON.stringify(t));
    if (t.with.text !== "news <no-reply \u00b7 job>" || t.with.job !== true || t.messages[0].from.name !== "news") throw Error("sender " + t.with.text);
    if (t.messages.map(m => m.text).join() !== "Day one,Day two" || t.at !== "2026-01-02T07:00:00Z") throw Error("oldest first");
    if (t.messages.some(m => m.mine) || t.received !== 2 || t.sent !== 0 || t.messages[1].conversation !== "cf2") throw Error("only theirs, with the conversation");
    if (!Mailbox.isUnread(t, {[t.key]: t.heard}) || Mailbox.isUnread(threads[1], {})) throw Error("unread follows the API, not what the mailbox saw");
    if (!Mailbox.inFolder(t, "inbox", {}) || Mailbox.inFolder(t, "sent", {})) throw Error("a job's thread is in the inbox");
    if (threads[1].agent !== "" || Mailbox.canReplyAll(t)) throw Error("a workflow has no agent; one counterpart");
    if (!Mailbox.matches(t, "day two") || !Mailbox.matches(t, "NEWS")) throw Error("search");
    if (Mailbox.labels.job !== "JOB") throw Error("badge");
    """)
  end

  test "a conversation a job's fire opened is in no folder, but its reviews still wait" do
    run!("""
    const ordinary = build(snap(), [prompt("1", "2026-01-01T10:00:00Z", "Hi")]);
    const fired = Mailbox.build("agency", "c2", snap({conversation: {created_at: "2026-01-01T09:00:00Z", job: "news"}, requests: [request("q1")]}), [prompt("1", "2026-01-01T10:00:00Z", "Hi")], me);
    if (ordinary.fire !== "" || !Mailbox.inFolder(ordinary, "sent", {})) throw Error("an ordinary conversation is a thread");
    if (fired.fire !== "news") throw Error("the job's name");
    for (const folder of ["inbox", "sent", "archive", "drafts"]) if (Mailbox.inFolder(fired, folder, {})) throw Error("not in " + folder);
    if (fired.pending.length !== 1) throw Error("its question still waits");
    """)
  end

  test "a preview strips Markdown marks and links" do
    run!("""
    const line = Mailbox.oneLine("**done:** see [the page](http://x.io/a) and `code`\\n\\n_pending_: more");
    if (line !== "done: see the page and code pending: more") throw Error(line);
    """)
  end

  test "a reply to a job's message is a new message to its agent that quotes it and keeps the job apart" do
    assert {"", 0} =
             GuiModules.run(
               ["Requests", "Model", "Jobs", "Mailbox", "Composers"],
               """
               const t = Mailbox.jobThreads("agency", [{id: "f1", job_id: "j1", sender: {kind: "job", name: "news"}, at: "2026-01-01T07:00:00Z", text: "Item 1\\nItem 2", conversation_id: "c9", run_ids: [], unread: true}],
                 [{id: "j1", name: "news", agent: "sales"}])[0];
               const r = Composers.replying(t, "", false, at => "07:00");
               if (r.kind !== "job" || r.subject !== "Re: news" || r.to.map(x => x.address).join() !== "sales@agency") throw Error(JSON.stringify(r));
               if (r.request !== "" || r.quoted !== null || !r.body.includes("On 07:00, news wrote:\\n> Item 1\\n> Item 2")) throw Error("quoted in the text: " + r.body);
               let s = Composers.open(Composers.empty(), r);
               if (s.items[0].to.length !== 1 || s.items[0].kind !== "job") throw Error("the composer opens to the agent");
               if (Composers.open(s, Composers.replying(t, "f1", false, at => "07:00")).items.length !== 1) throw Error("asked twice shows the same one");
               if (Composers.written(s.items[0], {subject: "Re: news", body: r.body, files: 0})) throw Error("the quote alone is nothing written");
               const none = Mailbox.jobThreads("agency", [{id: "g", job_id: "j2", sender: {kind: "job", name: "w"}, at: "2026-01-01T07:00:00Z", text: "x", conversation_id: "c", run_ids: [], unread: false}], [{id: "j2", name: "w", workflow: "flow"}])[0];
               if (Composers.replying(none, "", false, at => "").to.length !== 0) throw Error("a job with no agent starts with To empty");
               """
             )
  end

  test "a job proposal is a review in Pending, not mail, with its schedule and fields" do
    run!("""
    const create = {action: "create", name: "news", agent: "sales", message: "Summarise the news", schedule: "daily at 07:00", timezone: "Europe/Lisbon", delivery: "owner_inbox"};
    const reason = "Every morning, as asked.\\n\\njob news as it would run:\\nruns: sales is sent \\"Summarise the news\\"\\nwhen: daily at 07:00 (Europe/Lisbon)\\nnext fires: 2026-01-02T07:00:00+00:00, 2026-01-03T07:00:00+00:00\\n\\napprove creates it, edit sends back what to change, deny drops it";
    const options = {approve: [{name: "jobs", args: create}], edit: [], deny: []};
    const events = [prompt("1", "2026-01-01T10:00:00Z", "Every morning at 7 summarise the news")];
    const reply = {type: "reply", cursor: "9", at: "2026-01-01T10:06:00Z", request_id: "p1", actor: human, body: {body: "Shorter", option: "edit"}};
    const t = build(snap({runs: [run("r1", "sales", "closed")], requests: [request("p1", {reason, options})]}), events);
    if (t.reviews.length !== 1 || t.messages.some(m => m.request === "p1")) throw Error("held, not mail");
    const r = t.reviews[0];
    const job = r.job;
    if (r.kind !== "job" || r.summary !== "Sales proposes the job news" || r.text !== "" || r.files.length !== 0) throw Error(JSON.stringify(r));
    if (job.schedule !== "daily at 07:00" || job.timezone !== "Europe/Lisbon" || job.why !== "Every morning, as asked.") throw Error(JSON.stringify(job));
    if (job.create.agent !== "sales" || r.args.some(a => a.name === "action") || !r.args.some(a => a.name === "message" && a.value === "Summarise the news")) throw Error("target and fields");
    if (!r.outcome.includes("the job news is created as written")) throw Error(r.outcome);
    if (t.label !== "" || Mailbox.inFolder(t, "inbox", {})) throw Error("a proposal alone is no inbox mail");
    const edited = build(snap({runs: [run("r1", "sales", "closed")], requests: [request("p1", {reason, options, status: "closed"})]}), events.concat([reply]));
    const sent = edited.messages.filter(m => m.mine && m.request === "p1");
    if (sent.length !== 1 || sent[0].text !== "Edited: Sales proposes the job news\\n\\nShorter") throw Error(JSON.stringify(sent));
    const tool = Object.assign({}, create, {agent: undefined, tool: "ls"});
    if (build(snap({requests: [request("p2", {reason, options: {approve: [{name: "jobs", args: tool}]}})]}), events).reviews[0].job.create.tool !== "ls") throw Error("a tool job");
    const plain = build(snap({requests: [request("q", {options: {approve: [{name: "jobs", args: {action: "pause"}}]}})]}), events);
    if (plain.reviews.length !== 0) throw Error("only a create is a proposal");
    """)
  end
end
