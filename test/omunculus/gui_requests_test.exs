defmodule Omunculus.GuiRequestsTest do
  use ExUnit.Case, async: true

  alias Omunculus.GuiModules

  @fixtures """
  const human = {kind: "human", issuer: "local", subject: "1000"};
  const agent = name => ({kind: "agent", agent: name});
  """

  defp run!(modules, assertions) do
    assert {"", 0} = GuiModules.run(modules, @fixtures <> assertions)
  end

  test "a request's origin has no arbiter, which is no human" do
    run!(["Requests"], """
    if (Requests.human(undefined) || Requests.human(null)) throw Error("no participant is no human");
    if (Requests.kind({status: "pending", options: {}, origins: {}}, human) !== "team") throw Error("a request without arbiter is the team's");
    """)
  end

  test "pending, human, answer and label use participant-neutral fields" do
    run!(["Requests"], """
    const owner = {kind: "human", issuer: "local", subject: "1000"};
    const requests = [
      {status: "pending", arbiter: agent("worker")}, {status: "pending", arbiter: owner},
      {status: "closed", arbiter: owner}, {status: "escalated", arbiter: agent("worker")}
    ];
    if (requests.filter(Requests.pending).length !== 2) throw Error("pending requests missing");
    if (requests.filter(r => Requests.pending(r) && Requests.forYou(r, owner)).length !== 1) throw Error("for you count");
    if (Requests.isMe(agent("worker"), owner) || Requests.isMe(owner, {kind: "human", issuer: "local", subject: "2000"}) || Requests.isMe(owner, null)) throw Error("isMe");
    if (JSON.stringify(Requests.answer("", "Logo attached")) !== JSON.stringify({body: "Logo attached"}))
      throw Error("text replies must omit option");
    if (JSON.stringify(Requests.answer("approve", "")) !== JSON.stringify({body: "approve", option: "approve"}))
      throw Error("decision replies must retain option");
    if (Requests.label(agent("worker")) !== "worker" || Requests.label(owner) !== "local:1000") throw Error("participant label");
    """)
  end

  test "a request reads as a question or a review, for you or for another account" do
    run!(["Requests"], """
    const ask = over => Object.assign({status: "pending", arbiter: human, requester: agent("seller"), options: {}, origins: {}}, over);
    if (Requests.mark(ask({})).text !== "QUESTION" || Requests.mark(ask({})).icon !== "help") throw Error("question mark");
    const held = {action: "ask", summary: 'seller wants to ask test:client: "Ready?"', step: 1, of: 1};
    const review = ask({interception: held, options: {approve: [], edit: [], deny: []}});
    if (Requests.mark(review).text !== "REVIEW" || !Requests.review(review) || Requests.review(ask({}))) throw Error("review mark");
    const decision = ask({options: {approve: [], adjust: []}});
    const permission = ask({options: {grant: [{name: "grant", args: {kind: "tool", name: "deploy"}}], deny: []}});
    const marks = [ask({}), decision, permission, review].map(request => Requests.mark(request).icon + ":" + Requests.mark(request).text);
    if (marks.join() !== "help:QUESTION,diamond:DECISION,shield:PERMISSION,spark:REVIEW") throw Error("one name per kind " + marks);
    if (Requests.mark(decision).many !== "decisions" || Requests.mark(review).one !== "review") throw Error("nouns");
    if (Requests.line(ask({}), human) !== "from seller for you") throw Error(Requests.line(ask({}), human));
    if (Requests.line(ask({arbiter: agent("sales")}), human) !== "from seller to sales") throw Error("to another account");
    if (Requests.line(review, human) !== 'from seller for you') throw Error(Requests.line(review, human));
    const second = ask({interception: Object.assign({}, held, {step: 2, of: 3}), arbiter: agent("sales")});
    if (Requests.line(second, human) !== 'from seller to sales \\u00b7 step 2 of 3') throw Error(Requests.line(second, human));
    if (Requests.kind(review, human) !== "review" || Requests.kind(ask({}), human) !== "needs-you" || Requests.kind(review, {issuer: "local", subject: "2000"}) !== "team") throw Error("kinds");
    if (Requests.editable(review) !== "Ready?" || Requests.editable(ask({interception: {summary: "seller wants to run promote"}})) !== "") throw Error("editable text");
    if (Requests.party(human, human) !== "you" || Requests.party(agent("sales"), human) !== "sales" || Requests.party(human, null) !== "local:1000") throw Error("party");
    """)
  end

  test "unlocks says what a granted name lets the agent do" do
    run!(["Phrases", "Requests"], """
    if (Requests.unlocks(null, "") !== "") throw Error("nothing");
    if (Requests.unlocks({kind: "resource", name: "sandbox.network"}, "") !== "use the network") throw Error("network");
    if (Requests.unlocks({kind: "resource", name: "sandbox.write"}, "/site") !== "write files in /site") throw Error("write");
    if (Requests.unlocks({kind: "resource", name: "sandbox.write"}, "") !== "write files in its workspace") throw Error("write default");
    if (Requests.unlocks({kind: "tool", name: "publish_site"}, "") !== "publish site") throw Error("tool");
    if (Requests.unlocks({kind: "other", name: "x"}, "") !== "reach x") throw Error("reach");
    """)
  end

  test "options read and group as the card shows them" do
    run!(["Requests"], """
    const all = ["deny", "grant_agent", "grant_depth", "grant", "grant_workspace"];
    if (Requests.once(all, true).join() !== "grant") throw Error("once " + Requests.once(all, true));
    if (Requests.always(all, true).join() !== "grant_agent,grant_workspace") throw Error("always");
    // A decision that names an option grant_* offers it once, like any other.
    const decision = ["confirm_by_hand", "grant_network"];
    if (Requests.once(decision, false).join() !== "confirm_by_hand,grant_network") throw Error("decision once " + Requests.once(decision, false));
    if (Requests.always(decision, false).length !== 0) throw Error("a decision has no saved scopes");
    if (Requests.optionLabel("grant") !== "GRANT\u00a0\u00b7\u00a0THIS WORK ONLY") throw Error("grant label");
    if (Requests.optionLabel("grant_agent", {who: "clerk"}) !== "FOR CLERK") throw Error("agent label");
    if (Requests.optionLabel("approve") !== "APPROVE") throw Error("plain label");
    if (Requests.optionLabel("pedir-mudancas") !== "PEDIR MUDANCAS") throw Error("hyphen label");
    """)
  end

  test "a gathered permission grants whoever arbitrates it, so its scopes stay behind Always" do
    run!(["Requests", "Jobs", "Pending"], """
    const step = {name: "grant", args: {kind: "tool", name: "promote"}};
    const origin = {id: "o1", status: "pending", arbiter: agent("project-manager"), origins: {},
      options: {grant: [step], grant_agent: [step], grant_depth: [step], deny: []}};
    const top = {id: "t1", status: "pending", arbiter: human, options: {}, origins: {promote: origin}};
    const [choice] = Requests.choices(top);
    if (Requests.kind(origin, human) !== "team") throw Error("an agent's request is the team's");
    if (!Requests.grants(choice)) throw Error("grants");
    const parts = Pending.actions(choice.options, Requests.grants(choice));
    if (parts.once.join() !== "grant" || parts.always.join() !== "grant_agent") throw Error("scopes " + JSON.stringify(parts));
    const decision = {id: "o2", status: "pending", arbiter: agent("pm"), origins: {}, options: {accept: [], grant_x: []}};
    if (Requests.grants({options: ["accept", "grant_x"], request: decision})) throw Error("a decision grants nothing");
    """)
  end

  test "question is what the origins asked when the harness opened the request" do
    run!(["Requests"], """
    const low = {id: "a", requester: agent("designer"), reason: "1. font?\\n2. colour?", origins: {}};
    const mute = {id: "m", requester: agent("x"), reason: "  ", origins: {}};
    const top = {id: "c", requester: agent("sales"), reason: "sales left it unanswered", origins: {p: low, q: mute}};
    if (Requests.question(top, true) !== "1. font?\\n2. colour?") throw Error("noted: " + Requests.question(top, true));
    if (Requests.question(top, false) !== "sales left it unanswered") throw Error("own reason");
    if (Requests.question(low, true) !== "1. font?\\n2. colour?") throw Error("no origins keeps its reason");
    """)
  end

  test "contained hides the lower requests of a climb; kind and chain" do
    run!(["Requests"], """
    const low = {id: "a", status: "escalated", arbiter: agent("lead"), requester: agent("designer"), reason: "which font?", origins: {}};
    const mid = {id: "b", status: "escalated", arbiter: agent("seller"), requester: agent("lead"), reason: "font?", origins: {p: low}};
    const top = {id: "c", status: "pending", arbiter: human, requester: agent("seller"), reason: "Which font do you like?", origins: {q: mid}};
    const other = {id: "d", status: "pending", arbiter: human, requester: agent("sales"), reason: "Budget?"};
    const ids = Requests.contained([low, mid, top, other]);
    if (ids.size !== 2 || !ids.has("a") || !ids.has("b") || ids.has("c") || ids.has("d")) throw Error("contained");
    const names = Requests.chain(top).map(c => Requests.label(c.requester));
    if (names.join() !== "lead,designer") throw Error("chain " + names);
    if (Requests.chain(other).length !== 0) throw Error("empty chain");
    if (Requests.asker(top) !== "designer" || Requests.asker(other) !== "sales") throw Error("asker");
    if (Requests.route(top, false).join() !== "designer,lead,seller" || Requests.route(top, true).join() !== "designer,lead") throw Error("route");
    if (Requests.route(other, false).join() !== "sales") throw Error("route alone");
    if (Requests.kind(top, human) !== "needs-you" || Requests.kind(other, human) !== "needs-you") throw Error("needs-you");
    if (Requests.kind(low, human) !== "team") throw Error("team");
    if (Requests.kind(Object.assign({}, other, {status: "closed"}), human) !== "team") throw Error("closed");
    const options = {approve: [{name: "reply"}]};
    if (Requests.kind(Object.assign({}, other, {options}), human) !== "decision") throw Error("decision");
    const grant = {approve: [{name: "grant", args: {kind: "tool", name: "write"}}]};
    if (Requests.kind(Object.assign({}, other, {options: grant}), human) !== "permission") throw Error("permission");
    """)
  end

  test "holder follows a question up its climb; works are where it climbed from" do
    run!(["Requests"], """
    const low = {id: "a", status: "escalated", arbiter: agent("lead"), requester: agent("designer"), work_id: "w3", origins: {}};
    const mid = {id: "b", status: "escalated", arbiter: agent("seller"), requester: agent("lead"), work_id: "w2", origins: {p: low}};
    const top = {id: "c", status: "pending", arbiter: human, requester: agent("sales"), work_id: null, origins: {q: mid}};
    const loose = {id: "d", status: "escalated", arbiter: agent("seller"), requester: agent("lead"), work_id: "w2", origins: {}};
    const done = {id: "e", status: "closed", arbiter: human, requester: agent("sales"), work_id: "w1"};
    const all = [low, mid, top, loose, done];
    if (Requests.holder(low, all) !== top || Requests.holder(mid, all) !== top || Requests.holder(top, all) !== top)
      throw Error("holder of the climb");
    if (Requests.holder(loose, all) !== null || Requests.holder(done, all) !== null) throw Error("no holder");
    if (Requests.works(top).join() !== "w2,w3") throw Error("works " + Requests.works(top));
    if (Requests.works(done).join() !== "w1" || Requests.works(loose).join() !== "w2") throw Error("own work");
    """)
  end

  test "repeated finds the answered request a new one asks again" do
    run!(["Requests"], """
    const ask = (id, status, work, who) => ({id: id, status: status, arbiter: human, requester: agent(who), work_id: work, reason: "q", created_at: {a: "1", b: "2", c: "3", d: "4", p: "1", q: "2", r: "3", s: "4"}[id] || "5"});
    const replies = {a: {stamp: "09:48"}, b: {stamp: "09:50"}};
    const list = [ask("a", "closed", "w1", "lead"), ask("b", "closed", "w1", "lead"), ask("c", "closed", "w2", "lead"),
      ask("d", "closed", "w1", "other"), ask("n", "pending", "w1", "lead")];
    if (Requests.repeated(list[4], list, replies).id !== "b") throw Error("the last answered one");
    if (Requests.repeated(list[4], list.slice().reverse(), replies).id !== "b") throw Error("by when asked, not by order given");
    if (Requests.repeated(ask("n", "pending", "w1", "lead"), list.slice(0, 2).concat([Object.assign({}, list[4], {id: "z", status: "closed", created_at: "9"})]), Object.assign({z: {}}, replies)).id !== "b") throw Error("one asked later is no earlier one");
    if (Requests.repeated(ask("n", "pending", "w2", "lead"), list, replies) !== null) throw Error("answered request only");
    if (Requests.repeated(ask("n", "pending", "w1", "third"), list, replies) !== null) throw Error("same asker");
    if (Requests.repeated(list[0], [list[0]], replies) !== null) throw Error("not itself");
    // The preview, then the proposal, then the owner's decision: one asker, one
    // work, other options; none repeats the one before.
    const decide = (id, status, options) => Object.assign(ask(id, status, "w1", "seller"), {options: Object.fromEntries(options.map(option => [option, []]))});
    const preview = decide("p", "closed", ["aprovar", "pedir-mudancas"]);
    const proposal = decide("q", "closed", ["accept", "adjust", "refuse"]);
    const owner = decide("r", "pending", ["approve", "deny"]);
    const answered = {p: {stamp: "10:25"}, q: {stamp: "10:35"}};
    if (Requests.repeated(proposal, [preview, proposal], answered) !== null) throw Error("a proposal after a preview is no repeat");
    if (Requests.repeated(owner, [preview, proposal, owner], answered) !== null) throw Error("the owner's decision is no repeat");
    const again = decide("s", "pending", ["aprovar", "pedir-mudancas"]);
    if ((Requests.repeated(again, [preview, proposal, again], answered) || {}).id !== "p") throw Error("the same decision again is");
    // A grant of another thing is no repeat of the earlier grant.
    const grant = (id, status, name, at) => Object.assign(ask(id, status, "w1", "seller"), {created_at: at, options: {grant_once: [{name: "grant", args: {kind: "tool", name: name}}], deny: []}});
    const deploy = grant("g1", "closed", "deploy_preview", "1");
    const network = grant("g2", "pending", "network", "2");
    if (Requests.repeated(network, [deploy, network], {g1: {}}) !== null) throw Error("another resource is no repeat");
    const network2 = grant("g3", "pending", "network", "3");
    if ((Requests.repeated(network2, [deploy, Object.assign({}, network, {status: "closed"}), network2], {g1: {}, g2: {}}) || {}).id !== "g2") throw Error("the same resource again is");
    """)
  end
end
