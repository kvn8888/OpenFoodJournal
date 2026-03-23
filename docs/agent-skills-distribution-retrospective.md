# From Scattered Prompts to a Private Skills Registry: Building an Agent Memory System That Actually Works

I started this session wondering if the Vercel Skills CLI could help me keep agent prompts in sync across repos. I ended up redesigning how AI agents maintain project knowledge — because the real problem wasn't distribution, it was that agents kept forgetting what they learned.

## The Starting Point

I had three repos — OpenFoodJournal (Swift/iOS), polymarket-ev-bot (Next.js), and kvn8888.github.io (Next.js portfolio) — each with their own `.claude/skills/` directories and `.github/agents/` configurations. The skills had drifted apart. The stretch agent (my interactive Copilot agent that keeps a multi-step conversation alive in a single premium request) used `ask_user` in some repos and `vscode_askQuestions` in others. Only one of those actually works in VS Code.

The deeper problem: agents routinely failed to update project skills after making changes. They'd refactor an entire data flow, write a retrospective about it, and leave the project skill — the document that the *next* agent session reads first — completely stale.

## Step 1: Evaluating Vercel Skills CLI

The [Vercel Skills CLI](https://github.com/vercel/skills) (`npx skills`) is a tool for packaging and distributing "skills" — structured bundles of instructions that tell AI agents how to behave. Each skill has a `SKILL.md` with YAML frontmatter and a markdown body, plus optional `references/`, `scripts/`, and `assets/` directories.

I ran `npx skills list` in my OpenFoodJournal project and found 4 existing skills already installed:

```
openfoodjournal    .claude/skills/openfoodjournal
retrospective      .claude/skills/retrospective
skill-creator      .claude/skills/skill-creator
swiftui-expert     .claude/skills/swiftui-expert-skill
```

The CLI can pull skills from public GitHub repos, but my project-specific skills contain architecture details I don't want public. I asked the natural question: *do I have to make my skills public?*

Turns out, private repos work — with a caveat. The CLI uses `git archive` over HTTPS with a GitHub token, which works for private repos. But there's a [known bug (#436)](https://github.com/vercel/skills/issues/436) where globally installed skills from private repos get an empty `skillFolderHash` in `.skill-lock.json`, which breaks update detection.

## Step 2: Creating a Private Skills Registry

I created a private GitHub repo `kvn8888/agent-skills` as a central distribution point:

```bash
gh repo create kvn8888/agent-skills --private --description "Reusable AI agent skills"
```

The structure is simple — each skill gets its own directory under `skills/`:

```
skills/
├── retrospective/       # How to write technical retrospectives
│   ├── SKILL.md
│   └── references/
│       └── structure.md
├── skill-creator/       # How to create new skills
│   ├── SKILL.md
│   └── references/
│       ├── anatomy.md
│       └── example.md
├── swiftui-expert-skill/ # SwiftUI patterns and conventions
│   └── SKILL.md
├── openfoodjournal/     # iOS nutrition tracker project knowledge
│   ├── SKILL.md
│   └── references/
│       └── swiftui-patterns.md
└── stretch/             # Interactive agent meta-skill
    ├── SKILL.md
    └── references/
        ├── stretch.agent.md
        └── stretch.prompt.md
```

Installing a skill into any repo is one command:

```bash
npx skills add kvn8888/agent-skills --subdirectory skills/retrospective
```

Or list all available skills:

```bash
npx skills add kvn8888/agent-skills --list
```

The key insight: **separate reusable skills from project-specific ones.** The polymarket-ev-bot had a `polymarket/` skill with API details and betting logic — that's never going to be useful in another repo. But `retrospective`, `skill-creator`, and the `stretch` agent pattern are universal.

## Step 3: The Real Problem — Agents Don't Maintain Their Own Memory

While cataloging skills across repos, I noticed the stretch agent prompt had this rule:

```markdown
8. Start substantial work by consulting repo context and relevant skills,
   especially `CLAUDE.md`, the matching files under `.claude/skills/`,
   and any session retrospectives under `docs/`.
```

And this one:

```markdown
11. If a code or config change would leave `CLAUDE.md`, `.claude/skills/`,
    or relevant `docs/` retrospectives inconsistent, update those files
    in the same change set.
```

Both rules *tell* agents to maintain project skills but don't explain *why* or give *specific triggers*. The result: agents follow the letter of the law when they remember, but treat skill updates as optional busywork. They'd add a whole new API route and never update the project architecture map in the skill file.

This is the classic LLM instruction problem: **vague rules get vague compliance.**

## Step 4: The Memory Triad Rewrite

I rewrote the stretch agent with what I'm calling the "memory triad" — three principles that explain the *reasoning* behind skill maintenance:

### Principle 1: The Project Skill IS Long-Term Memory

Old rule 8 said "consult skills." New rule 8 explains *why*:

```markdown
8. Start substantial work by consulting repo context and relevant skills
   — especially the project skill (the living document that IS the project's
   long-term memory) and any session retrospectives under `docs/`.
   The project skill is the single source of truth for any agent working
   on this repo — it survives across sessions, context compactions, and
   different users. Read it first, update it last.
```

The key phrase is "survives across sessions." Chat history gets compressed and eventually lost. The project skill persists. When an agent understands that the skill is its own future memory, it's more motivated to keep it accurate.

### Principle 2: Retrospectives ≠ Project Skills

Old rule 9 just said "create a retrospective." New rule 9 draws a clear line between two types of documentation:

```markdown
9. **Retrospectives are for humans. Project skills are for agents.**
   Both capture knowledge, but the project skill is what the next agent
   session will read before writing any code.
```

This matters because agents were dumping architectural decisions into retrospectives (which humans read on Hacker News) instead of project skills (which agents read before coding). The audience distinction drives the right behavior.

### Principle 3: Concrete Triggers, Not Vague Guidelines

Old rule 11 said "don't leave things inconsistent." New rule 11 gives a checklist:

```markdown
11. **Keep the project skill current as a live document.** Update in the
    SAME commit as the code change whenever:
    - You add, remove, or rename a model, service, view, or API endpoint
    - You discover a gotcha that cost debugging time
    - Architecture decisions change (new dependency, changed data flow)
    - A convention or pattern is established or abandoned
    - Project metadata becomes inaccurate (versions, URLs, env vars)
    - You add new files or directories that change the codebase map
    
    **Do NOT leave the update for "later" or assume someone else will do it.**
    A stale project skill is worse than no skill — it actively misleads
    the next agent session.
```

The last line is the most important: "A stale project skill is worse than no skill." It reframes neglecting the update from "minor oversight" to "actively harmful."

### The Institutional Memory Paragraph

I also added a closing reinforcement:

```markdown
**The project skill is the project's institutional memory.** Chat history
gets lost. Retrospectives are for human readers. The project skill is what
the next agent reads on line 1. If you learned something important — a
gotcha, a pattern, a decision — and you only put it in chat or a
retrospective, it's effectively lost for future agent sessions.
```

## Step 5: Propagating Changes Across All Repos

With the improved prompt written, I synced it across four locations:

1. **`kvn8888/agent-skills`** — the canonical reusable version in `skills/stretch/references/stretch.agent.md`
2. **OpenFoodJournal** — project-specific version referencing `.claude/skills/openfoodjournal/SKILL.md`
3. **polymarket-ev-bot** — fixed `ask_user` → `vscode_askQuestions` and added all improvements
4. **kvn8888.github.io** — same fixes, same improvements

Each repo got a descriptive commit:

```
Sync stretch agent with improved version

- Fix ask_user -> vscode_askQuestions (correct tool name)
- Rule 8: Explain project skill as long-term agent memory
- Rule 9: Clarify retrospectives=human, project skills=agent
- Rule 11: Add concrete trigger list for skill updates
- Add institutional memory paragraph
```

## The Gotcha: `ask_user` vs `vscode_askQuestions`

The polymarket and portfolio repos had `ask_user` throughout their stretch agents. That tool name doesn't exist in VS Code — the correct one is `vscode_askQuestions`. The agent would silently fail when trying to checkpoint, breaking the core stretch workflow (staying in one premium request).

This is a subtle but representative problem: prompts get copy-pasted between environments, and subtle API differences between Claude Code, Copilot, Cursor, and Windsurf mean a prompt that works perfectly in one environment breaks silently in another.

The fix was adding rule 10:

```markdown
10. Always use `vscode_askQuestions` for checkpointing with the user.
    This is the canonical tool for interactive check-ins in VS Code.
```

Being explicit about the tool name — rather than saying "use the appropriate tool" — eliminates the ambiguity.

## What I'd Do Differently

**Version the canonical prompt.** Right now, the reusable version in `agent-skills` and the project-specific versions diverge immediately because project-specific versions reference local skill paths. I should have a templating system or at least a diff-friendly structure that makes syncing easier.

**Test the private repo bug workaround.** The empty `skillFolderHash` bug means `npx skills update` might not detect changes to privately-hosted skills. I should write a simple CI check that compares installed skill hashes against the source repo.

**Measure whether the memory triad actually works.** Right now this is a hypothesis: that explaining *why* and giving *concrete triggers* will lead to better skill maintenance. The real test is whether agents in future sessions actually update the project skill when they should. I should track this across a few sessions.

## What's Next

- **Template system for stretch agents** — A base template in `agent-skills` plus per-project overrides, so syncing doesn't require manual diffing
- **Automated skill sync CI** — A GitHub Action that checks if installed skills match their source repo versions
- **Effectiveness measurement** — Track across 10 sessions whether agents update project skills after code changes, comparing the new prompt against the old one

---

*The best agent prompt isn't the one that lists the most rules — it's the one that makes the agent understand why each rule exists.*
