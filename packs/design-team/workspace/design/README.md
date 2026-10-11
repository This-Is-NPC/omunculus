# Design

The visual proposal of the site, made before it is built. The builders
work from `handoff.md` once the client and the owner approve it.

- `briefing.md`: the briefing, from `templates/design-brief.md`.
- `rounds.md`: the revision rounds, each its number, what the client
  asked and what changed.
- `handoff.md`: the pages in scope, the palette and type with their
  values, spacing and components, the assets the client still owes and
  every placeholder. Not published.
- `preview/`: what homologation shows, plain HTML and CSS with no build
  step: `index.html`, `moodboard/`, `wireframes/`, `mockup/`. The
  workspace's `Dockerfile` serves it with nginx on port 80 until the site
  is built.

Placeholders are named as placeholders, `[texto do cliente]`, never
content invented as the client's. No secret, key or production address
goes here.
