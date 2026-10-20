---
name: release-notes
description: How Moonlight writes the release notes of a version — the file, its headings, the order of the sections and how each change is written. Read it before writing release notes.
---

# Release notes at Moonlight

Release notes go in `RELEASE_NOTES.md`, newest version first.

Each version starts with a level-2 heading: `## v<version> — <date>`, the
date as `YYYY-MM-DD`, an em dash between them.

Under it, these sections, in this order, each a level-3 heading, leaving
out a section with no change:

1. `### Breaking`
2. `### Added`
3. `### Fixed`

Each change is one bullet: `- <what changed> (#<issue>)`, starting with a
verb in the past tense, the issue number from the change list.
