.pragma library

// The same arithmetic as Omunculus.Usage.sum on the server, per model call.
function tally() {
  return { calls: 0, input: 0, cached: 0, output: 0, cost: 0, priced: 0 };
}

function number(value) { return typeof value === "number" ? value : 0; }

// Adds one model call's reported usage (OpenAI or Anthropic shape) to `into`.
function add(into, usage) {
  const reported = usage || {};
  into.calls++;
  into.input += number(reported.input_tokens || reported.prompt_tokens)
    + number(reported.cache_creation_input_tokens) + number(reported.cache_read_input_tokens);
  into.cached += number(reported.cache_read_input_tokens)
    + number((reported.prompt_tokens_details || {}).cached_tokens);
  into.output += number(reported.output_tokens || reported.completion_tokens);
  if (typeof reported.cost === "number") {
    into.cost += reported.cost;
    into.priced++;
  }
  return into;
}

// A sum of money in US dollars: four decimals under a cent, else two.
function money(spent) {
  return "US$ " + (spent < 0.01 ? spent.toFixed(4) : spent.toFixed(2));
}

// The server's GET /usage as the cost view reads it: {agents: name -> its
// entry, total}; an agent's `usd` is null when its model has no price.
function spend(data) {
  const agents = {};
  for (const item of (data && data.agents) || []) agents[item.agent] = item;
  const total = (data && data.total) || {};
  return { agents: agents, total: { usd: number(total.usd), unpriced: total.unpriced || [] } };
}

// What the cost view says about models without a price, one line each; none
// when every model that ran has one.
function unpriced(total) {
  return (total.unpriced || []).map(model => "no price set for " + model + " in the project config");
}

// The works of the tree (Tree.rows) with what each used, for the cost view's
// BY WORK: {row, agent, model, own, branch, share}. `own` and `branch` are
// token tallies — the work's, and with every work below it — never dollars:
// the server prices an agent, not a work. The front agent's own are the
// tokens of the calls made outside any work (`works[""]`) and its branch is
// everything. `share` is the branch's part of the tokens of `all`, 0 to 1.
// `models` maps an agent to its entry in the server's usage (`spend().agents`).
function byWork(rows, works, all, models) {
  const used = tally => number(tally.input) + number(tally.output);
  return rows.map(row => {
    const front = row.kind === "front";
    const agent = front ? row.front.agent : row.node.agent;
    const own = front ? Object.assign(tally(), works[""] || {}) : row.node.own.usage;
    const branch = front ? all : row.node.branch.usage;
    return { row: row, agent: agent, model: (models[agent] || {}).model || "", own: own, branch: branch, share: used(all) > 0 ? used(branch) / used(all) : 0 };
  });
}
