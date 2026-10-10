# Assessment of Opus 5.5's recommendation

Read the [addendum](addendum.md) with the [original review](review.md). This was
a persistent, subscription-authenticated `claude -p` review requested by Kevin;
the main model was verified from final `modelUsage`, not just the command flag.

## What I agree with

- Keep dedicated Azure on Responses. Runtime model slug and deployment are
  separate concerns. Generic API protocol selection can be a later explicit
  setting; don't silently turn reasoning off to bypass the 400.
- Fix model metadata reconciliation before merging the Azure branch. I checked
  `RuntimeModelCatalog.swift:157-190`: the fallback can find the configured old
  model's record when the reported new model has no record. It can then associate
  the new ID with old limits/prices. This is a pre-existing lookup behavior that
  becomes especially relevant with editable slugs, not newly introduced code.
- Harden existing compaction before layering on native opaque compaction:
  durable checkpoint saves, bounded portable summaries, better handling of
  omitted content, protected constraints, usage anchors, safe tool-group cuts,
  and bounded overflow recovery.
- Keep continued processing and provider background mode separate. A Live
  Activity is display; an OS execution grant or server-side job is what performs
  work. An upper iteration bound is not a percentage complete.
- For Apple Intelligence, start with an explicit limited local provider and a
  small-context design. Full automatic fallback is a separate routing choice.

## Corrections and boundaries

- The research already verified Azure's `store:true` requirement; Opus's fetch
  omitted that section. The resumed addendum accepts the supplied evidence.
- A blanket `ModelContext.rollback()` could discard unrelated work. Failed
  checkpoint cleanup must be scoped to that checkpoint.
- Existing write execution records, NutritionStore mutations, and HealthKit sync
  already provide idempotency foundations. Audit their crash/atomicity behavior;
  don't describe them as absent or guarantee exactly-once external side effects.
- `read_conversation_source` cannot retrieve arbitrary omitted transcript IDs.
  A retrieval stub needs a real same-thread transcript retrieval capability.
- Omitted history remains saved and the app shows a context-limited warning.
  The concern is the model's access to that evidence, not deletion of user data.
- A rejected oversized provider request is not established as billable. Opus's
  wording that it 'fails and gets billed' was not independently verified.
- Approval interruption is still a hypothesis requiring control-flow tracing;
  the review did not establish that backgrounding durably records a user denial.
- For a reported-model mismatch, use trustworthy metadata for the reported
  model when available; use conservative limits/unknown price only when it isn't.
  Don't blindly lowercase provider request IDs; normalize catalog lookup keys
  while preserving user-entered deployment/model identifiers on the wire.
- The review rechecked OpenAI/Microsoft pages but relied on our earlier Pi,
  OpenCode and Hermes research. Apple pages failed in its WebFetch tool; relevant
  Apple Markdown evidence was supplied in the resumed follow-up. Unverified
  for Opus does not invalidate the earlier sourced research.

No implementation changed during this review. No build, tests, live provider
probe, PR push, or deployment was performed. Recommended next work: repair Azure
metadata mismatch, then compaction correctness, then a background-execution
feasibility prototype. The original code remains pending hosted CI.
