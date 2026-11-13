.pragma library

const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function two(n) { return String(n).padStart(2, "0"); }

function hm(date) { return two(date.getHours()) + ":" + two(date.getMinutes()); }

// "Today", "Yesterday" or "03 Nov", from the days between and the day's date.
function word(days, dayOfMonth, month) {
  return days === 0 ? "Today" : days === 1 ? "Yesterday" : two(dayOfMonth) + " " + months[month];
}

function dayWord(date, now) {
  const today = new Date(now);
  const midnight = new Date(today.getFullYear(), today.getMonth(), today.getDate());
  const days = Math.round((midnight - new Date(date.getFullYear(), date.getMonth(), date.getDate())) / 86400000);
  return word(days, date.getDate(), date.getMonth());
}

// An offset in minutes as a label: "UTC", "-03", "+05:30".
function offsetLabel(minutes) {
  if (minutes === 0) return "UTC";
  const abs = Math.abs(minutes);
  return (minutes < 0 ? "-" : "+") + two(Math.floor(abs / 60)) + (abs % 60 ? ":" + two(abs % 60) : "");
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

// The local time zone's abbreviation at an instant, "-03" or "UTC". QML
// formats it ("t"); the fallback writes the offset the same way.
function zone(iso) {
  const date = new Date(iso);
  return typeof Qt !== "undefined" ? Qt.formatDateTime(date, "t") : offsetLabel(-date.getTimezoneOffset());
}

const written = /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d)(?::\d\d(?:\.\d+)?)?([+-])(\d\d):(\d\d)$/;

// A moment as `began` says it, with its zone: "Today 21:59 -03". A stamp that
// writes an offset ("2026-11-13T18:00:00-03:00", as the server writes when a
// job runs) shows the wall time it was written with, in that offset, and the
// day is read there too; any other stamp is read in the local zone.
function zoned(iso, now) {
  const parts = written.exec(iso);
  if (parts === null) return began(iso, now) + " " + zone(iso);
  const minutes = (parts[6] === "-" ? -1 : 1) * (Number(parts[7]) * 60 + Number(parts[8]));
  const there = new Date(now + minutes * 60000);
  const days = Math.round((Date.UTC(there.getUTCFullYear(), there.getUTCMonth(), there.getUTCDate()) - Date.UTC(parts[1], parts[2] - 1, parts[3])) / 86400000);
  return word(days, Number(parts[3]), parts[2] - 1) + " " + parts[4] + ":" + parts[5] + " " + offsetLabel(minutes);
}
