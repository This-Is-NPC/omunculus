.pragma library

function number(value) { return typeof value === "number" ? value : 0; }

// A sum of money in US dollars: four decimals under a cent, else two.
function money(spent) {
  return "US$ " + (spent < 0.01 ? spent.toFixed(4) : spent.toFixed(2));
}

// What the server says nothing about: no calls, no dollars.
const none = { replies: 0, input: 0, fresh: 0, cache_write: 0, cached: 0, output: 0, cost: 0, usd: null, models: [], unpriced: [] };

// The server's GET /usage as the cost view reads it: {agents: name -> its
// entry, works: id -> its {own, branch, calls}, total}. Dollars are the
// server's, priced per call by the model each call used; an entry's `usd` is
// null when none of its calls has a price.
function spend(data) {
  const agents = {};
  for (const item of (data && data.agents) || []) agents[item.agent] = item;
  const works = {};
  for (const item of (data && data.works) || []) works[item.work] = item;
  const total = Object.assign({}, none, (data && data.total) || {});
  total.usd = number(total.usd);
  return { agents: agents, works: works, total: total };
}

// What the cost view says about models without a price, one line each; none
// when every model that ran has one.
function unpriced(total) {
  return (total.unpriced || []).map(model => "no price set for " + model + " in the project config");
}

// The works of the tree (Tree.rows) with what each cost, for the cost view's
// BY WORK: {row, agent, own, branch, calls, share}. `own` and `branch` are
// the server's entries — the work's, and with every work below it — and
// `calls` each model call of the work. The front agent's own are the calls
// made outside any work and its branch is everything. `share` is the
// branch's part of the dollars of `data.total`, 0 to 1.
function byWork(rows, data) {
  const spent = entry => number(entry.usd);
  return rows.map(row => {
    const front = row.kind === "front";
    const found = data.works[front ? "" : row.node.work] || {};
    const branch = front ? data.total : found.branch || none;
    return {
      row: row,
      agent: front ? row.front.agent : row.node.agent,
      own: found.own || none,
      branch: branch,
      calls: found.calls || [],
      share: spent(data.total) > 0 ? spent(branch) / spent(data.total) : 0
    };
  });
}
