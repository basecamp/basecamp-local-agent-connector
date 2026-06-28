# basecamp-local-agent-connector — Skills

Skills for AI coding assistants following the [Agent Skills](https://agentskills.io/specification)
spec. This repo ships the `/basecamp` skill, which drives local Claude Code
agents from Basecamp via the connector bridge (`bin/connect`).

## Install

```bash
npx skills add jorgemanrubia/basecamp-local-agent-connector
```

This installs the skill content. The skill also needs the connector runtime
(`bin/connect`, the `basecamp` CLI, and Tailscale) — see the [README](README.md)
for full setup.

## Contributing

1. Create `skills/SKILL_NAME/SKILL.md` with YAML frontmatter (`name`,
   `description`, `triggers`).
2. Add supporting files to `skills/SKILL_NAME/references/` if needed.
3. Add an entry to the README.
