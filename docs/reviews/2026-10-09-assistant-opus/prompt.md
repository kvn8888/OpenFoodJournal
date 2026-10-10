# Opus 5.5 independent recommendation

Kevin requests a read-only second opinion on context compaction and the related
Azure, iOS background completion, and Apple Intelligence work. Use your final
answer for the report; do not edit files or run commands. Date: 2026-10-09.

Working directory is the task worktree, based on origin/testflight 44cc46b.
Current implementation commit is 681dc2e. The main checkout elsewhere is older.
Read these first, but challenge their assumptions:
- docs/assistant-context-background-research.md
- docs/apple-intelligence-fallback-research.md
- docs/reviews/2026-10-09-assistant-opus/implementation.diff

Then inspect relevant portions (not entire giant files) of:
- OpenFoodJournal/Services/ChatContextAccumulator.swift
- OpenFoodJournal/Services/ChatService.swift: preparedContext, createCheckpoint,
  contextBlocks, runTurn, suspendForBackgrounding, storedChatRequestConfig
- OpenFoodJournal/Services/ChatModelProxy.swift: configured factory and adapters
- OpenFoodJournal/Models/AIProviderSettings.swift
- OpenFoodJournal/Services/RuntimeModelCatalog.swift
- OpenFoodJournalTests/ChatFeatureTests.swift and RuntimeModelCatalogTests.swift

Questions in priority order:
1. Recommend production-ready compaction inspired by current Pi, OpenCode v2,
   and Hermes. Distinguish existing behavior, concrete defects, and proposals.
   Cover full-request accounting, actual usage anchors, opaque reasoning and
   signatures, complete tool groups, summary-input budgets, native versus
   portable compaction, protected constraints/approvals, atomic checkpoint saves,
   source retrieval, huge single turns, provider switches, and bounded recovery.
2. Review Azure editable base-model slug plus separate deployment. Legacy enum
   values now identify Fast/Smart slots, not a model allowlist. User saw HTTP 400
   with gpt-6.1-sol through the generic compatible provider: function tools plus
   reasoning unsupported on chat/completions; use responses or effort none.
   Dedicated Azure uses Responses. Generic compatible uses Chat Completions.
   Is directing Azure to its dedicated adapter enough, or should generic API
   protocol be selectable? Find actual defects in the change if present.
3. Recommend how AI runs can finish after leaving the iOS app. Distinguish
   ActivityKit display, BGContinuedProcessingTask, provider background mode,
   URLSession restrictions, lock/force-quit, local tools/HealthKit, approvals,
   persistence and exactly-once writes. Azure docs say background needs
   store:true; OpenAI has different current retention rules. Don't assume Live
   Activity grants execution or guarantee force-quit completion. Address honest
   progress for indeterminate multi-turn AI work.
4. Secondary: critique Apple Intelligence as a no-key fallback. Separate iOS
   26.2 baseline from iOS 27 APIs, device availability/entitlements, small context,
   tool bridging, text help versus scanning versus icon generation. Challenge
   unsupported claims in the research note.

Constraints:
- SwiftData/CloudKit authoritative; provider-neutral transcript and sources.
- BYOK Keychain credentials; no server, cloud retention change, silent provider
  fallback or weaker write approvals without an explicit product decision.
- No app builds, simulator installs, live paid model probes, git writes, edits,
  commands, releases, subagents, credential access, or notifications.
- Do not read .env, auth files, keychain exports, personal data or sensitive logs.
- Available tools are read/search only. Verify time-sensitive facts with official
  docs as useful; report links are starting points, not proof. Separate upstream
  specifications from implementation evidence.
- Eight tool turns, ten-minute wall timeout. Read efficiently and deliver a final
  recommendation within the bound. Don't spend a turn merely announcing a plan.

Return Markdown (about 1,200-2,000 words maximum): an executive recommendation
for a junior SWE, prioritized findings with code lines/evidence, minimal design
and implementation order, disagreements, acceptance tests, owner decisions,
sources actually checked and review limitations. Do not claim tests passed.
