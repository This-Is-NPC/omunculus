.pragma library

const days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

function pad(value) { return String(value).length < 2 ? "0" + value : String(value); }

function plural(count, unit) { return count + " " + unit + (count === 1 ? "" : "s"); }

// A cron day-of-week field in words, "" when it is not one this reads.
function weekdays(field) {
  if (field === "*") return "day";
  if (field === "1-5") return "weekday";
  if (/^[0-7]$/.test(field)) return days[Number(field) % 7];
  return "";
}

// A job's schedule as a person says it: "Every day at 07:00 (Europe/Lisbon)".
// The forms are those of `Omunculus.Jobs.Schedule`: `every Nm`, `every Nh`,
// `daily at HH:MM` and a 5-field cron expression; one this does not read
// comes back as written.
function words(schedule, timezone) {
  const text = String(schedule || "").trim();
  const zone = timezone ? " (" + timezone + ")" : "";
  let match = /^every (\d+)([mh])$/.exec(text);
  if (match) return "Every " + (match[2] === "m" ? plural(Number(match[1]), "minute") : plural(Number(match[1]), "hour")) + zone;
  match = /^daily at (\d{1,2}):(\d{2})$/.exec(text);
  if (match) return "Every day at " + pad(match[1]) + ":" + match[2] + zone;
  const cron = text.split(/\s+/);
  if (cron.length === 5) {
    const at = /^\d+$/.test(cron[0]) && /^\d+$/.test(cron[1]) ? pad(cron[1]) + ":" + pad(cron[0]) : "";
    const day = cron[2] === "*" && cron[3] === "*" ? weekdays(cron[4]) : "";
    if (at !== "" && day !== "") return "Every " + day + " at " + at + zone;
    const step = /^\*\/(\d+)$/.exec(cron[0]);
    if (step && cron.slice(1).every(field => field === "*")) return "Every " + plural(Number(step[1]), "minute") + zone;
  }
  return "On the schedule " + text + zone;
}

// The instants of a proposal's "next fires: a, b, c" line, [] when it has none.
function nextFires(reason) {
  const match = /^next fires: (.+)$/m.exec(String(reason || ""));
  return match ? match[1].split(", ").map(at => at.trim()).filter(at => at !== "") : [];
}

// What a job costs per fire, in words. `target` is {agent|workflow} or null for
// a tool, which runs with no model; `preview` is {estimate_usd, basis} once
// the server has answered, null while it has not. With no history the server
// gives no figure, and the basis says so.
function estimate(target, preview) {
  if (!target) return "None: it runs a tool, with no model";
  if (!preview) return "Reading the recent runs...";
  const usd = preview.estimate_usd;
  const basis = String(preview.basis || "");
  if (typeof usd !== "number") return basis !== "" ? basis : "No estimate: no earlier runs to go by";
  return "About $" + (usd < 0.01 ? usd.toFixed(4) : usd.toFixed(2)) + " per fire" + (basis !== "" ? ", " + basis : "");
}
