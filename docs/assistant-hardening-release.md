# Assistant hardening — consolidated TestFlight release

Date: 2026-10-10. PR: https://github.com/kvn8888/OpenFoodJournal/pull/98.
Implementation collaborated with the persistent Claude Opus 5.5 session recorded
in `reviews/2026-10-09-assistant-opus/session.md`. Hosted CI is the compilation and
unit-test gate; there were no local app builds or automated phone UI tests.

## Included

- Editable Azure Fast/Smart base-model slugs separate from deployments; existing
  settings/backup migration; Responses routing, Foundry resource URL support.
- Reported-model metadata cannot inherit unrelated configured-model pricing or
  limits. Unknown metadata means conservative limits and usage-only cost.
- Bounded portable compaction input, incremental chunks, output limits, failed
  summary cooldown, no-progress detection, and checkpoint save-error handling.
- Whole-turn preservation and shortened oversized tool-result projections with
  explicit omissions. Original messages, images, PDFs, and sources stay stored.
- Hash-based usage anchors persist inside existing round JSON and invalidate
  after changed prefixes, model/provider, instructions, or schemas. Estimates
  reserve previous output conservatively; they are still estimates.
- Small-window budgets no longer reserve more than the window. Saved constraints
  survive fitting; an unfit protected set fails clearly rather than dropping it.
  Ordinary fallback conversation is lossy evidence, not a permanent constraint.
- Durable approval outcomes are included outside lossy summaries. Ledger-save
  errors stop writes before execution. Background interruption is not a denial.
- One provider-overflow retry only before provider output, after measured input
  reduction. Output-truncated responses fail explicitly. Partial streamed tool
  calls cannot execute on Continue without a completed provider-turn boundary.
- Best-effort iOS continued processing, system Live Activity phases, cancellation,
  expiry recovery, and locked-device HealthKit guards. Real provider events drive
  indeterminate progress. Approval waits release the OS task.
- Response Info distinguishes configured/reported models and can queue compacting
  older turns for the next message.

## Intentionally not included

- Provider-side background mode remains off: no change from Azure `store:false`.
- No guaranteed execution after force-quit or when iOS refuses background work.
- Native opaque provider compaction, generic endpoint protocol selector, and
  Apple Intelligence are follow-up features; the research remains available.
- A new raw transcript-history retrieval tool was rejected by automatic approval
  review as additional saved-content egress. It was not added or worked around.
  Only already-supported source IDs can be reopened. Missing transcript details
  must be restated by the user; read tools can fetch current journal facts.

## Review findings addressed

Opus implemented the initial compaction helper and tests; Codex integrated output
caps, usage anchors, background lifecycle, metadata correction, durable approvals,
and provider incompleteness checks. Opus's final review prompted moving ordinary
fallback messages out of protected constraints, correcting retrieval wording,
using remaining context for normal output limits, and treating approval waits
as paused rather than successfully completed background work.

Two review suspicions were checked in code: the `estimatedInput` helper does use
the anchor at admission, and approved writes reacquire execution. Anchors still
fall back safely when fingerprints don't match; tests cover prefix changes and
model changes. The production system prompt's changing journal facts often make
that invalidation appropriate. Whole-request model/token accounting remains
conservative; this does not claim vendor-tokenizer accuracy.

## Verification and release evidence

Offline tests added for custom slugs, model mismatch, backup migration, provider
request shapes/output caps, compaction chunks, save failures, tiny budgets,
protected constraints, manual compaction, overflow bounds, hash anchors,
background admission/expiry/stale callbacks, approval interruption, failed ledger
saves, and incomplete provider turns. Opt-in Azure live tool round trip skips
without explicit credentials; mandatory Gemini image CI is unchanged.

Local Swift syntax parsing and plist/whitespace validation passed. The release
PR's final checks and comments are authoritative for complete compile/unit counts,
archive/upload, commit identity, and TestFlight processing. Earlier CI failures
were a main-actor default-argument initializer, a missing required backup fixture
argument, and Swift's optional async-closure inference; all were corrected.

## Manual beta checklist — not executed

- [ ] Configure Azure model slug `gpt-6.1-sol` and a distinct deployment; test
  connection, send text, invoke a read tool, approve a write, inspect model/cost.
- [ ] Check old Azure settings and restored JSON backup still select the same
  deployment; an unknown reported model shows usage-only pricing.
- [ ] Long conversation, PDF, image, source retrieval and repeated compaction;
  verify original messages remain and omitted material is identified.
- [ ] Queue manual compaction in response Info; verify no request occurs until send.
- [ ] Leave the app mid-response; inspect system activity and return to completion
  or an honest Continue state. Repeat with lock, network loss and OS cancellation.
- [ ] Confirm indeterminate progress appears acceptably on a physical device;
  no fake percentages. iOS can expire a task that appears stalled.
- [ ] Background while approval is pending; Continue must ask again, never deny
  on the user's behalf or duplicate a write. Verify Apple Health reconciliation.
- [ ] Force-quit and relaunch: recover the last saved boundary without claiming
  the request completed, automatically spending again, or executing a partial call.

The new background API is beta functionality until these physical-device checks
are completed. Its failure/expiration fallback is the existing persisted Continue
path, which is exercised by deterministic tests.
