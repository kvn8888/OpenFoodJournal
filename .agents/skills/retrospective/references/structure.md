# Retrospective Structure

## Recommended Sections

```markdown
# [Title — descriptive, not generic. "From X to Y" or "Building Z" format]

[Opening paragraph: What existed before, what was wrong with it, and what this session set out to fix. 2-3 sentences max.]

## The Starting Point
[Describe the system as it was. Architecture, pain points, tech debt. Include a diagram or code snippet if it helps. The reader should understand *why* change was needed.]

## Step N: [Action-Oriented Title]
[For each major piece of work, cover:
- What was the goal?
- What approach was chosen and *why*?
- What broke or surprised you? (This is the interesting part.)
- What was the fix?
- Show a focused code snippet (5-15 lines max) of the interesting bit.]

[Repeat Step sections as needed. Usually 2-4 steps.]

## The Gotcha: [Debugging Story Title]
[Optional but valuable. A dedicated section for the most interesting debugging moment. Structure: symptom → investigation → root cause → fix. Junior devs learn the most from these.]

## The Revision: [What I Corrected Later]
[Optional but recommended when later debugging changed the story. Cover: what you originally thought was true, what new evidence changed your mind, and how the final implementation differs from the first draft.]

## What's Next
[Forward-looking. What's unfinished, what would you do differently, what does the roadmap look like. This turns a report into something worth revisiting.]

---
[Closing one-liner. Memorable, not generic.]
```

## Checklist Before Finalizing

- [ ] Every tool/library mentioned is explained on first use (one line is enough)
- [ ] Every decision has a "because" — no unexplained choices
- [ ] At least one "it broke" moment is included with full symptom→fix narrative
- [ ] If later work changed the solution, stale sections were rewritten or removed
- [ ] Code snippets show the *interesting* parts, not boilerplate
- [ ] A junior developer could follow the reasoning without external research
- [ ] The closing line is worth reading
