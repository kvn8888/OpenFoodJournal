# Build 7 — Assistant Runtime Hardening

Implementation date: 2026-07-21
App version: 1.4 (7)
Epic: [#25 — Agent foundations](https://github.com/kvn8888/OpenFoodJournal/issues/25)

## Delivered

- Synchronous `ChatService.submit(...)` persists the trigger message, attachments, and queued run before configuration or networking. One app-wide send gate prevents duplicates.
- Direct `@Query` transcript observation plus deterministic ordinals repairs missing or duplicate ordering after legacy and CloudKit merges.
- `ChatService` now coordinates persisted run phases, run-linked messages/tools, partial-answer snapshots, cancellation, suspension, explicit Continue, safe-read recovery, and uncertain-write protection.
- `ChatDeadlinePolicy.fast` uses 1s local reads, 3s HealthKit, 10s web search/first provider event, 15s fetch, 8s stream idle, 90s model turns, and 3m active runs. Approval time is unbounded and excluded.
- Safe operations retry at most once with 250ms plus/minus 20% jitter. `Retry-After` greater than five seconds becomes a visible manual-retry state. Writes and ambiguous interruptions never auto-retry.
- Independent read-only tool calls run in parallel with a maximum concurrency of three. Writes and approval-requiring calls remain sequential barriers, while provider order, call IDs, Gemini thought signatures, and Azure encrypted continuations remain intact.
- The provider stream contract now normalizes encoding, headers, provider events, visible text, completion, request IDs, and optional transport metrics.
- Redacted diagnostic spans cover send, context, encoding/upload, first provider event/text, model rounds, tools, approval wait, persistence/finalization, and active runtime. Detailed diagnostics and legacy AI logs prune after 14 days; terminal run state and usage/cost aggregates remain.
- Per-round and daily usage/cost accounting records provider, model/deployment, cached input, output, reasoning, request IDs, retries, and pricing-catalog provenance. Unknown pricing displays Usage only.
- Context UI distinguishes the frozen next-request estimate, selected cap, reserved output/tool headroom, last provider-reported input/cached input, and compaction/pruning/cache reconciliation.
- Assistant UI includes an immediate truthful glass activity card, elapsed/Still waiting state, genuine reasoning summaries only, grouped tool chips, Stop/Retry, completed run details, conversation/tab activity markers, and a global banner outside the Assistant tab.
- `get_nutrition_context` combines journal totals, goals, entries, micronutrients, and optional HealthKit energy. Food Bank search results include micronutrients.

## Post-build-7 local follow-up: Turso diagnostic sink

- New scan, Assistant, tool, model-round, Tavily, and Parallel diagnostics are written as redacted append-only `AIDiagnosticEvent` rows in the user-configured Turso database rather than being inserted into SwiftData/CloudKit.
- A local-only outbox is capped at 500 events, 2 MiB, and 48 hours; acknowledged UUIDs are removed immediately. It is delivery state, not diagnostic history.
- Existing `GeminiScanLog` and `ChatDiagnosticSpan` CloudKit rows migrate in bounded batches and are deleted locally only after Turso acknowledges the upserts. The model types remain as decoding compatibility shells.
- `ofj_ai_diagnostic_events` retains 14 days and is excluded from generation pruning. Usage/cost aggregates, conversations, source artifacts, run recovery, and write ledgers remain in SwiftData/CloudKit.
- Settings exports and clears the remote diagnostic table, shows pending/last-upload status, and the read-only `turso_debug.py ai-events` command filters by provider, status, operation, run ID, or request ID.
- Remote telemetry excludes prompts, answers, journal/HealthKit values, source URLs/content, attachments, provider bodies/model-attempt payloads, image data, credentials, and chain-of-thought.

This follow-up is verified in the working tree but is not evidence that the already-uploaded build 7 archive contains it.

## Verification evidence

- `OpenFoodJournalUnitTests` compiles the app plus non-UI unit/provider-contract test bundle for generic iOS with code signing disabled.
- Test inventory: 119 total test methods, comprising 115 non-live tests and four opt-in live provider contracts after the Turso diagnostic additions.
- Live-provider contracts skip unless `OFJ_RUN_LIVE_CHAT_TESTS=1` and matching provider credentials/deployments are present.
- Automated phone/simulator UI tests were intentionally not run.
- The current host cannot execute the compiled unit bundle: its default CoreSimulator store is unavailable, an isolated simulator device set is not discoverable by `xcodebuild`, and the connected phone has no installed development provisioning profile. This is an execution-environment blocker, not a compile failure.
- Release archive: `.asc/artifacts/OpenFoodJournal-1.4-7.xcarchive` (`ARCHIVE SUCCEEDED`).
- App Store export: `.asc/artifacts/export-7/OpenFoodJournal.ipa` (`EXPORT SUCCEEDED`).
- IPA SHA-256: `5d9ab8f2161cf81319cce1c76e4aa164324cb1252882ad95e97986201a4daf83`.
- Archived app executable SHA-256: `88ac2dd7b56b2d8b54104cb66b2c250a139e607014d8f2b539215f2258d1d506`.
- App Store Connect build ID: `895c393f-76a6-4b22-b7ec-2980ed02dce4`; processing state `VALID`; internal state `IN_BETA_TESTING` through the all-builds `Testing` group.

## Unexecuted internal TestFlight smoke checklist

- [ ] Send a text message and confirm the bubble plus Preparing card appear immediately.
- [ ] Confirm Waiting for Provider and Still waiting after three seconds reflect real activity without fake reasoning or percentages.
- [ ] Run journal reads, Food Bank micronutrient search, `get_nutrition_context`, and a three-call parallel read group.
- [ ] Exercise a write approval Allow, Deny, Retry, and Stop; confirm no duplicate journal mutation.
- [ ] Search with native, Tavily, and Parallel providers; fetch HTML, image, and PDF sources; send direct image and PDF attachments.
- [ ] Confirm durable sources remain readable after another message and after compaction.
- [ ] Background during provider streaming, read tools, approval, and a write boundary; relaunch and use Continue where safe.
- [ ] Switch among Gemini, OpenRouter, Azure Sol, and Azure Terra; verify preserved call IDs/signatures/continuations.
- [ ] Confirm the context meter stays frozen while streaming and reconciles only after completion.
- [ ] Confirm completed-run details and exported AI logs contain provider/model, TTFT, durations, tool rounds, request IDs, usage, and known cost without prompt/journal/source content.
- [ ] Confirm Clear AI Diagnostics does not reset retained usage/cost aggregates, and Reset AI Usage does not delete conversations.
- [ ] Leave the Assistant tab during a run and confirm the originating conversation marker and global banner remain active.

The checklist is intentionally attached as unexecuted evidence for internal TestFlight validation; no manual result is implied by its presence.
