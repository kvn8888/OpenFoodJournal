---
name: stretch
description: Start a stretch session with proactive subagents, web research, skill/doc updates, and retrospective maintenance.
agent: stretch
tools: [search, web, read, edit, agent]
---

Use the Stretch agent for repository work that benefits from continuous checkpointing.

Session defaults:
- Start by consulting `.claude/skills/openfoodjournal/SKILL.md` (canonical project knowledge), the SwiftUI expert skill, and any relevant session retrospectives under `docs/`.
- Use subagents proactively for independent search, research, debugging, or implementation tracks.
- For current web facts and docs, prefer Copilot web search. When you hand web research to a subagent, explicitly tell it that Copilot web search is usually the best tool for up-to-date web lookups.
- When you discover durable repo facts or workflow changes, update the project skill and relevant docs during the same session.
- If a code or config change would leave `.claude/skills/openfoodjournal/SKILL.md`, `.claude/skills/`, `.github/agents/`, `.github/prompts/`, or relevant `docs/` retrospectives inconsistent, update them in the same change set.
- When the work is substantial, create a retrospective with the retrospective skill, and revise that retrospective later if subsequent fixes change the story.
- End every response with `vscode_askQuestions` unless the user explicitly ends the session.
