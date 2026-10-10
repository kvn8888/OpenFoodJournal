Kevin now explicitly authorizes you and Codex to collaborate on implementing the
review recommendations as one TestFlight release. Continue the same session.

YOUR OWNERSHIP for this bounded implementation pass:
- OpenFoodJournal/Services/ChatContextAccumulator.swift
- OpenFoodJournal/Services/ChatService.swift (ONLY context preparation/checkpoint
  creation/retrieval and overflow retry paths; do not change provider setup or
  lifecycle except where necessary for compaction)
- New helper file OpenFoodJournal/Services/ChatCompactionSupport.swift if useful
- Relevant context tests in OpenFoodJournalTests/ChatFeatureTests.swift and
  ChatRuntimeHardeningTests.swift or a new dedicated test file.
Codex owns RuntimeModelCatalog, provider settings/Apple integration, background
coordinator and app wiring. Do not edit those or project/workflow files.

Implement the most important compaction fixes with tests:
1. Checkpoint save errors must propagate and clean up only the checkpoint inserted
  by this attempt, preserving prior boundary and unrelated edits; no blanket
  rollback. Inject a save hook for deterministic failure tests if necessary.
2. Summary input must be bounded and portable: visible messages, compact tool
  call/result text, attachment/source references; no opaque provider continuation
  items and no raw image bytes. Budget summary output and instructions too.
  Chunk the old prefix using complete exchange boundaries with incremental
  summaries. Bounded attempts and no-progress protection. Avoid multiple paid
  summaries for unchanged context on repeated failure.
3. Don't silently lose omitted blocks: prefer covering them in checkpoint;
  deterministic fallback must explicitly mark incomplete evidence and expose
  retrievable same-thread source references. If full transcript retrieval would
  need touching tool registry, propose its interface for Codex to integrate.
4. Budget tiny models honestly (4K total); remove admission/output/tool floors
  that exceed selected cap. Preserve complete parallel tool exchanges; handle
  enormous tool results through bounded portable projection, not arbitrary
  history splitting. If a current user message/attachment itself cannot fit,
  reject clearly rather than truncating it silently.
5. Stop estimating opaque encrypted payload as ordinary text. Add safe actual
  usage anchoring only if it can be tied to request/prefix identity and invalidated
  after edits/model/system/tools changes. Otherwise report remaining work for next
  bounded pass instead of implementing a misleading approximation.
6. One provider-overflow recovery attempt, only before visible output or tool
  execution, and only after reduction; no retry loop or duplicate writes.

Read relevant source before editing. Use existing style and unit harness.
No local xcodebuild/app build/simulator, no live provider calls, secrets, push,
commits, release changes, or subagents. You MAY edit owned files now. Parent
handles scoped commits and hosted CI. Avoid Bash; Read/Edit/Write/Grep/Glob tools
are enough. Max 8 turns in this pass, wall timeout 600s. Work efficiently and
report implemented parts, tests added, risks, follow-up work at the end even if
not all parts fit. Do not merely provide a plan. Keep request-layer portable
transcripts and existing signatures/call IDs intact for normal noncompacted turns.
