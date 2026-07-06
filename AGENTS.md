# basecamp-local-agent-connector — Skills

Skills for AI coding assistants following the [Agent Skills](https://agentskills.io/specification)
spec. This repo ships the `/basecamp-connect` skill, which drives local Claude Code
agents from Basecamp via the connector bridge (`bin/connect`).

## Install

```bash
npx skills add basecamp/basecamp-local-agent-connector
```

This installs the skill content. The skill also needs the connector runtime
(`bin/connect`, the `basecamp` CLI, and Tailscale) — see the [README](README.md)
for full setup.

## Updating the installed skill — always, when it exists

`npx skills add` installs a **snapshot copy** (canonically at
`~/.agents/skills/basecamp-connect`, symlinked into per-agent directories like
`~/.claude/skills`). Editing `skills/` in this repo does **not** change that
copy. So whenever you modify a skill here and an installed copy exists, you must
refresh it — otherwise the user keeps running the stale version:

1. Edit the skill source in `skills/<name>/` (this repo).
2. Commit and push to `main` (the installer fetches from GitHub, not the local
   clone).
3. Refresh the installed copy: `npx skills update -g` (drop `-g` for a
   project-level install).

Check for an installed copy with `ls ~/.agents/skills/` — if
`basecamp-connect` is there (and isn't a symlink into this repo), steps 2–3 are
part of finishing the change, not optional follow-up.

## Contributing

1. Create `skills/SKILL_NAME/SKILL.md` with YAML frontmatter (`name`,
   `description`, `triggers`).
2. Add supporting files to `skills/SKILL_NAME/references/` if needed.
3. Add an entry to the README.
