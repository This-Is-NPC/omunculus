.pragma library

const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function two(n) { return String(n).padStart(2, "0"); }

function hm(date) { return two(date.getHours()) + ":" + two(date.getMinutes()); }

function dayWord(date, now) {
  const today = new Date(now);
  const midnight = new Date(today.getFullYear(), today.getMonth(), today.getDate());
  const days = Math.round((midnight - new Date(date.getFullYear(), date.getMonth(), date.getDate())) / 86400000);
  return days === 0 ? "Today" : days === 1 ? "Yesterday" : two(date.getDate()) + " " + months[date.getMonth()];
}

// Every function takes an ISO stamp, read in the local time zone, and `now`
// (milliseconds) where a day word is wanted.

// The day: "Today", "Yesterday" or "03 Nov".
function day(iso, now) { return dayWord(new Date(iso), now); }

// A chat stamp: "21:59" today, else "Yesterday 21:59" or "03 Nov 21:59".
function clock(iso, now) {
  const date = new Date(iso);
  const word = dayWord(date, now);
  return word === "Today" ? hm(date) : word + " " + hm(date);
}

// When something began: "Today 21:59", "Yesterday 21:59" or "03 Nov 21:59".
function began(iso, now) {
  const date = new Date(iso);
  return dayWord(date, now) + " " + hm(date);
}

// A log time to the second: "21:59:07".
function second(iso) {
  const date = new Date(iso);
  return hm(date) + ":" + two(date.getSeconds());
}

// A precise log time: "21:59:07.123".
function precise(iso) {
  const date = new Date(iso);
  return hm(date) + ":" + two(date.getSeconds()) + "." + String(date.getMilliseconds()).padStart(3, "0");
}

// A whole moment: "03 Nov 2026 21:59:07.123".
function full(iso) {
  const date = new Date(iso);
  return two(date.getDate()) + " " + months[date.getMonth()] + " " + date.getFullYear() + " " + precise(iso);
}

// The local time zone's abbreviation at an instant, "-03" or "UTC": what
// follows a time that says when a job runs, since the job's own zone is
// elsewhere. QML formats it ("t"); the fallback writes the offset the same way.
function zone(iso) {
  const date = new Date(iso);
  if (typeof Qt !== "undefined") return Qt.formatDateTime(date, "t");
  const minutes = -date.getTimezoneOffset();
  if (minutes === 0) return "UTC";
  const abs = Math.abs(minutes);
  return (minutes < 0 ? "-" : "+") + two(Math.floor(abs / 60)) + (abs % 60 ? ":" + two(abs % 60) : "");
}

// A moment as `began` says it, with its zone: "Today 21:59 -03".
function zoned(iso, now) { return began(iso, now) + " " + zone(iso); }
