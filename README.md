# Omunculus

Omunculus is a local workflow harness for tool-using agents. The project
targets Elixir 1.17, OTP 27, Deno 2.9, and Bubblewrap on Linux.

Run the test suite with `mix test`. The live model test requires
`--include local_model`, `OMUNCULUS_OPENAI_URL`, and `OMUNCULUS_OPENAI_MODEL`.

The JavaScript adapter exposes native tool calls and `__omunculus_execute` for
`await tools.name(args)`.

Each project configuration must contain an `[execution]` table. It declares
the Bubblewrap backend, runtime roots, permitted environment names, and
execution limits.
