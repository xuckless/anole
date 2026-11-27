# anole-zig agent skill

An Agent Skills skill for AI coding agents that build
backends with [Anole](https://github.com/xuckless/anole), the Zig 0.17 backend
framework. Agents have no training data on Anole and mostly know older Zig, so
they hand-roll middleware, auth, pools, rate limits, rooms, jobs and the rest.
The skill makes them look up what Anole already has before writing code, and
shows the Zig 0.17 idioms Anole code uses.

`SKILL.md` is the entry point: the one rule, the capability index and a
minimal app. `references/` holds one file per topic. `apis.txt` lists every
public Zig name the skill mentions, for a check that they all exist.

## Install

- **`anole init` / `anole new`** write it into new projects as
  `.claude/skills/anole-zig/`, plus a line in `AGENTS.md` that points at it.
- **`anole skill install [--project|--user]`** installs it into an existing
  project or your user skills directory (coming in 0.7.1).
- **`npx skills add xuckless/anole`** installs it from this repository's
  `skills/anole-zig/` path. Pin the tag that matches the Anole version in your
  `build.zig.zon`.

## Versioning

The skill matches the Anole version it ships with: the names and patterns in
it are those of that release. After upgrading Anole, reinstall the skill from
the same tag.
