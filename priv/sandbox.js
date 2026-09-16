// The host resolves every tools.* call. This process has no ambient permissions.
const encoder = new TextEncoder();
const pending = new Map();
let nextId = 0;
const send = (value) => Deno.stdout.writeSync(encoder.encode(JSON.stringify(value) + "\n"));
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

async function execute({ code, names }) {
  const tools = Object.create(null);
  for (const name of names) {
    tools[name] = (args = {}) => new Promise((resolve, reject) => {
      const id = ++nextId;
      pending.set(id, { resolve, reject });
      send({ type: "call", id, name, args });
    });
  }
  try {
    const result = await new AsyncFunction("tools", code)(Object.freeze(tools));
    send({ type: "result", output: typeof result === "string" ? result : JSON.stringify(result ?? null) });
  } catch (error) {
    send({ type: "error", output: String(error) });
  }
  Deno.exit(0);
}

let started = false;
let buffer = "";
for await (const chunk of Deno.stdin.readable.pipeThrough(new TextDecoderStream())) {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf("\n")) !== -1) {
    const message = JSON.parse(buffer.slice(0, newline));
    buffer = buffer.slice(newline + 1);
    if (!started) {
      started = true;
      void execute(message);
    } else {
      const waiter = pending.get(message.id);
      pending.delete(message.id);
      if (!waiter) continue;
      if (message.ok) waiter.resolve(message.output);
      else waiter.reject(new Error(message.output));
    }
  }
}
