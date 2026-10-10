# Integration review of the current worktree (read-only)

I read the code only. Nothing was built or tested, so nothing here is confirmed to compile or pass.

## High priority

**H1. A local fallback can make a thread permanently unable to compact.**
- `deterministicCheckpoint` turns every user message into a protected constraint: `constraints.append("User said: …")`, then `protectedConstraints(constraints)` (`ChatService.swift:2643`, `:2665`).
- `protectedConstraints` only trims and removes exact duplicates. It never caps or drops anything (`:2716-2720`).
- The fitting step can't remove constraints, so the save throws "Important saved constraints do not fit" (`:2510-2513`).
- Once a summary fails, the 10-minute cooldown (`:2433`) sends the next attempt straight to the deterministic path, which fails the same way. A long thread on a 50k budget (about a 6,250-token checkpoint allowance, roughly 37 user messages of 500 characters each) becomes unusable until the user picks a larger budget. A tiny budget (512 tokens) breaks after about 3 messages.
- Model-written summaries have a slower version of the same problem: constraints only accumulate across compactions (`:2489`, `:2588`), and dedup only removes exact matches. If the model rephrases a constraint, the old wording stays alongside the new one.
- **Fix:** the fallback should put "User said:" lines into a lossy field, not protected constraints. Protected constraints need an explicit size limit with a disclosed policy for what gets dropped.

**H2. Ordinary turns now cap output at the *budget reserve*.**
- `maximumOutputTokens: contextUsage?.reservedOutputTokens` (`ChatService.swift:1709`) means 5,000 tokens on any 50k budget. That includes unknown Azure slugs and conservative descriptors, even under the Balanced preset.
- The Responses adapter sends this as `max_output_tokens` (`ChatModelProxy.swift:2033-2034`), and that limit includes reasoning tokens. Reasoning models running tool loops can come back truncated or with no visible output.
- The reserve is a budgeting assumption, not a desired output limit. Use the remaining window instead: `min(descriptor max output, selectedLimit − estimated input)`.
- Also verify how each adapter surfaces `incomplete` / `max_output_tokens`. I didn't check that.

## Medium priority

**M1. Summary output cap combined with reasoning.** `maximumOutputTokens: budget.outputTokens` (`:2568`) is 512 tokens on a tiny budget and 6,250 on 50k. On reasoning models, the reasoning can use up that allowance, the summary fails validation, and the code falls back to the deterministic path, which leads straight into H1.

**M2. The usage anchor only affects the compaction trigger.**
- `inputTokenEstimate` feeds only the first plan's trigger (`ChatContextAccumulator.swift:132`).
- The admission check, the fold path, the hard guard, `lastPreparedInputEstimate`, and the displayed usage all use the heuristic `estimatedInput` (`ChatService.swift:2112-2197`).
- If the anchor is *lower* than the heuristic, the plan skips compaction, but the fold path (`:2118`) then compacts anyway under a different policy. If the anchor is *higher*, it triggers early.
- The target loop also mixes the anchored total with heuristic block costs (`Accumulator.swift:132-146`).
- Not dangerous, but the two estimates contradict each other. Pick one estimate per request and use it for every check.

**M3. The anchor may never match in some setups.**
- The anchor is created with `catalogResolution.selection` (`:1793`), but lookups use the effective selection (`:2053`). The fingerprint includes `baseModelID`.
- With the runtime catalog these probably match: the alias is cached at `:1773` before resolution, and when there's no record the fallback descriptor keeps the original base ID.
- When `modelCatalog == nil`, or the provider omits the model ID, they may not match, and the system silently falls back to heuristics. That's safe, but anchoring might never actually run.
- I found no test where a second round consumes an anchor. Add one using the production selection path.

**M4. Retrieval claims could mislead the model.**
- The fallback note says "The original messages remain in this conversation; reread durable evidence…" (`ChatService.swift:2614`).
- The tool-result projection says "complete result remains… reread… using a listed source ID" (`ChatCompactionSupport.swift:172`).
- The summary-input clip marker says "the original remains in this conversation" (`:149`).
- The model has no tool that can read raw transcript text. The projection's `source_ids` also come from the whole turn, not from the result that was cut, so results from tools like `query_entries` may list unrelated or no sources.
- **Reword to:** "stored in the app but not available to you; only listed source IDs can be reread; re-run read tools for current journal data." The user-visible warning at `:2202` is accurate for the UI.

**M5. The protected approval history has no size limit.** `protectedAuthorizationContext` (`:2724-2733`) appends one line per write to *every* system prompt. That text can't be compacted, so it grows until long threads hit the hard limit, and small budgets get there quickly. It's counted in the estimates, so it fails clearly rather than silently. It also changes after each write, which correctly invalidates the anchor.

## Low priority

- **L1. Approval releases the background lease as a success.** `backgroundExecution?.finish(success: true)` runs while the run is still waiting for approval (`:3019`). That reports the system task as complete, and no new lease is requested after approval. Use `success: false`, or add a distinct "paused" handling.
- **L2. Pending-approval cancellation looks correct.** The order is cancel, then `try Task.checkCancellation()` at `:3055` before any denial is saved, with an "interrupted" diagnostic. Confirm with a test where the app is backgrounded during the approval wait.
- **L3. Background details I couldn't verify.**
  - Indeterminate progress (`totalUnitCount = -1`, `ChatBackgroundExecution.swift:108`) could count as "minimal progress" and get the task ended first under resource pressure. That needs a device check.
  - Registering a new identifier after launch for each run (`:139`) needs on-device confirmation.
  - The `identifiers` entry stays behind if registration fails. Harmless.
  - The Info.plist wildcard `$(PRODUCT_BUNDLE_IDENTIFIER).assistantCompletion.*` matches the code's prefix for both Debug and Release.
- **L4. Confusing message after a failed overflow retry.** When overflow recovery can't reduce the request, the hard guard (`:2171-2186`) throws the "message and its attachments" error before the recovery-specific message at `:2192` can run.
- **L5. Possible double count in the context meter.** `refreshCurrentContextEstimate` adds `protectedAuthorizationContext` again (`:2250`). That's a double count if the prompt it receives already includes it, which only happens if it's given the augmented prompt. Check the call sites.

## Things I checked that looked fine

- The overflow limit is cleared at the start and end of `runTurn` (`:1583-1584`).
- The anchor fingerprint covers provider, model, endpoint, routing, system prompt, tools, and every message part, including continuations and attachment hashes. Edits, checkpoints, projections, and prompt changes all invalidate it.
- The Anthropic usage mapping keeps uncached and cached input separate (`ChatModelProxy.swift:1482-1484`). I didn't verify how the final `input` value is put together.

## Limits of this review

- I didn't read: `RuntimeModelCatalog` changes, app wiring, `persistModelRound`, the HealthKit guard bodies, the manual compaction queue (`queuedCompactionThreadIDs`), the new tests, or the backup tests.
- I compared nothing against the commits by diff; I only read the current files.
- I have no evidence any test passes.
- No transcript retrieval tool exists, and none should be added. The wording issue is M4.
