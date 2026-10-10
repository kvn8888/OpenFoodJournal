# Addendum to the second opinion

## What the corrections change

**1. Azure `store:true` (supplied evidence).** I retract my "unverified" label. The research note was right. Microsoft's Limitations section says background mode needs `store=true`, and stream resumption needs the original request to use `stream=true`. Our Azure adapter always sends `store:false` (`ChatModelProxy.swift:2021`). So Azure background mode can't happen as a quiet payload change. It is a data-retention decision for you as owner.

**2. Progress (supplied Apple doc).** No, an upper bound of 8 is not a truthful total.
- Most runs end in 1–3 rounds, so "3 of 8" would read as 37% when the run is nearly done.
- A run that hits the cap stops because of the cap, not because the work is finished.
- Apple ends low-progress tasks first under resource pressure. That creates a pull to inflate progress, which is exactly the fake percentage you've ruled out.

Two things to keep separate:
- **Text status (honest):** for example "Completed 3 rounds · waiting for model". It's a count, not a fraction.
- **Determinate progress (only where real):** for example "tool 2 of 4 in this round", because the model has already returned those 4 calls.

The supplied doc doesn't establish whether a continued-processing task may report indeterminate progress, or how the system treats it. That needs a device spike: a debug build on a non-production device, never the phone with the real journal. If indeterminate progress isn't accepted, don't use continued processing for model-wait phases. Background work would then stay as today: suspend and offer Continue. Force-quit gives no cancellation callback, so saving after every round is required, not optional.

**3. Ledger and `NutritionStore`.** I withdraw "add idempotent writes." The work is an audit of what already exists:
- Is the ledger intent saved *before* the write?
- Is the "committed" marker saved in the *same* save as the `NutritionStore` change?
- How are HealthKit writes deduplicated? They sit outside SwiftData, so they can't be atomic with it. Check whether sync-identifier metadata is used.

I also withdraw blanket `rollback()`. If a checkpoint save fails, clean up only the checkpoint object: unlink it, don't activate it, keep the previous one. A separate `ModelContext` for checkpoint writes could work, but its merge behavior would need checking first.

**4. Omitted turns.** Agreed: a placeholder alone gives the model nothing it can fetch. Preferred fix: fold omitted blocks into the checkpoint, which the chunked summarizer (D2) makes possible. Fallback: a read-only tool that fetches a range of messages from the current thread. Saving turns as source artifacts would duplicate data into CloudKit, so avoid that.

**5. B1** stays a hypothesis. Trace the order between `task.cancel()` and `resolvePermission(.denied)` (`ChatService.swift:857-858`) and the code that consumes the permission (~`2703`). The question is whether a denial tool result is ever saved, or whether cancellation always wins.

## Final implementation order

**0. Investigate (no code):**
- Trace B1.
- Audit the ledger, `NutritionStore`, and HealthKit write path.
- Device spike on continued-processing progress.

**1. Fix this branch before merge:**
- A1: when Azure reports a different model than the slug, fall back to unknown limits and price and show the mismatch.
- A2–A3: slot name in errors, case-insensitive slug lookup.

**2.** Checkpoint save with error handling, cleanup scoped to the checkpoint, and a cooldown.

**3.** Portable summarizer input with a size cap, chunked when needed.

**4.** Fold omitted blocks into the checkpoint. Add the range tool only if folding isn't enough.

**5.** A separate protected list for approvals and constraints.

**6.** Usage anchors.

**7.** Splitting inside a single huge turn, plus one overflow retry.

**8.** Continued processing, but only if steps 0's spike and audit pass.

**9.** Optional: native compaction cache, provider background mode, on-device Apple provider.

## Decisions that need you (owner)

- Azure/OpenAI `store:true` retention for background mode.
- What to do if the spike shows indeterminate progress isn't accepted: skip background execution, or show status only.
- Local notifications for approvals waiting while the app is backgrounded.
- An explicit Chat Completions / Responses selector for the generic provider.
- A connection test that declares a tool (small paid usage per test).
- Apple Intelligence as an explicit choice vs automatic selection.

## Routine engineering (no product decision)

- A1–A3, D1–D7.
- The B1 trace and the ledger audit.
- A read-only range tool scoped to the current thread.
- Acceptance tests.

Nothing here is authorized to be implemented by this review, and nothing has been built or tested.
