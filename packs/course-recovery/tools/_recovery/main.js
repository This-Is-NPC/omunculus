import { correct, inspectCase, routed } from "./recovery.js";

const input = JSON.parse(await new Response(Deno.stdin.readable).text());
const [mode, ...args] = Deno.args;
const handlers = { correct, route: routed, inspect: inspectCase };
try {
  console.log(JSON.stringify(handlers[mode](input, ...args)));
} catch (error) {
  console.log(JSON.stringify({ ok: false, output: error.message, emit: [] }));
}
