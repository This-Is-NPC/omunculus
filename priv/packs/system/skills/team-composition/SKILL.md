---
name: team-composition
description: Fit teams together in this project — import a pack at the depth it should work, on the project's models and logins, and adjust what one team tells another so they agree before anyone answers the person.
---

# Composing teams

1. Read the project with `config` and `overview`, in parts: without
   arguments each lists what there is — which agents answer the person
   at depth 0, which teams work below; `config` with `section` `models`
   and `auth` gives the models and logins that exist.
2. Decide where each team works. Several agents may answer the person at
   depth 0, each in conversations of its own (the person names the agent
   they talk to). A team that serves another works below it: import it
   with `depth` set to how many depths below its own.
3. Propose the import with `propose_pack`: `path` to the pack's folder,
   `models` mapping each of its roles to a model the config has, `auth`
   mapping each provider it names to a login the config has, `depth`.
   The request says where each agent would run; the person approves it.
4. Adjust how the teams speak to each other with `propose_config`, an
   agent's item holding only what changes (its `text`, or its `tools`).
   A team made to answer the person speaks of "the person": once it works
   below another team, the one who asks is that team's agent, so its
   front agent's text says so.
   The agent above hands work down with `work`, naming the agent below
   (`## Agents` lists them); the agent below stops with its questions or
   objections (break), and the one above answers by sending the work back
   (reopen). Write it so the team that answers the person does so only
   once the team below has agreed that what was asked can be done as
   asked. Tell an assessment apart from a build in the work itself: a work
   that asks only whether something can be done, what blocks it and what
   could be done instead is answered without building anything; the build
   is a work of its own, sent once what was assessed has been agreed.
5. One proposal at a time. After each is applied, read the project again
   before the next.
