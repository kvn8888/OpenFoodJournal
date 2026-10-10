# Second opinion: context compaction, Azure models, background runs, Apple Intelligence

I only read code and docs. I did not build, run tests, or call any paid model. Everything below comes from reading source at `681dc2e` plus a few official docs.

## Executive recommendation

1. **Compaction:** fix four real defects before adding anything new:
   - older turns that get dropped without being summarized,
   - no size limit on what gets sent to the summarizer,
   - checkpoint saves that fail silently,
   - no way to recover when one turn is too big on its own.

   After that, add "usage anchors" (budgeting from the token counts the provider reports) and a separate list of protected user rules. Native provider compaction can come later, as an optional speed-up.
2. **Azure:** sending Azure users to the dedicated adapter (the code that talks to Azure's Responses API) is the right fix, and it's enough for Azure. The branch adds a new risk, though: a wrong model slug quietly gives wrong limits and prices. Show a mismatch when Azure reports a different model. Make the generic provider's protocol (Chat Completions vs Responses) selectable later, as a clearly labeled advanced setting. Never auto-switch it.
3. **Background:** use `BGContinuedProcessingTask` for runs the user starts. Report progress as "round N of at most 8". Pause for approvals instead of treating them as denied. Add idempotent writes, meaning a retried write can never create a duplicate. Provider-side background mode is a separate, opt-in data-retention decision.
4. **Apple Intelligence:** the research note is mostly careful. Ship an explicit "On-device" provider first, not "Automatic", and don't reuse today's checkpoint format at 4K tokens.

## 1. Compaction: prioritized findings

These are separated into existing behavior, defects confirmed in code, and proposals.

**Existing behavior (works as intended):**
- A "block" is one whole user turn: the user message plus every model and tool step until the next user message. That keeps tool calls and their results together (`ChatService.swift:2214-2222`).
- Compaction starts at 80% of the limit and always keeps at least the two most recent blocks (`ChatContextAccumulator.swift:124-139`).
- If summarizing fails, a deterministic fallback builds the checkpoint instead (`ChatService.swift:2295-2298`).
- An old checkpoint is only reused if its boundary message and timestamps still match the transcript (`ChatService.swift:2165-2195`). That part is good.

**Defects (all confirmed in code):**

- **D1 (high): dropped turns become invisible to the model.** The trimming loop at `ChatService.swift:2029-2038` removes whole blocks *after* the checkpoint was made. Those turns end up in neither the checkpoint nor the request. The only trace is a warning saying they were omitted. The original transcript is still in SwiftData, but the model gets no placeholder, so it can't know to fetch them. Fix: put these blocks into a new checkpoint. If you truly must drop something, insert a stub like "N turns omitted, IDs …, use `read_conversation_source`".
- **D2 (high): the summarizer request has no size limit and isn't portable.**
  - `createCheckpoint` sends the raw message prefix to the model, including the provider's opaque continuation data, function calls and results, and attachments, while declaring no tools (`tools: []`) (`ChatService.swift:2269-2281`).
  - This branch makes overflow more likely. An existing user who changes the slug from `gpt-5.6-sol` (922k limit) to `gpt-6.1-sol` (unknown, so 50k) can have a history far bigger than 50k. That history gets sent in one summarizer call, which fails and gets billed, and the code then falls back to the deterministic checkpoint.
  - Some providers also reject tool-call history when no tools are declared. I didn't verify this per adapter.
- **D3 (medium): checkpoint saves fail silently.** The save uses `try? modelContext.save()` (`ChatService.swift:2329`).
  - I disagree a little with the research note on the impact. The inserted object stays in memory, and a later `try?` save (`ChatService.swift:1967`) may persist it anyway. After a crash, the next run just compacts again.
  - So the real harm is hidden failures and repeated paid compaction, not corrupted state. The fix is still: save first, roll back on error, keep the old checkpoint active, and wait before retrying.
- **D4 (medium): one huge turn can't be compacted.** The last two blocks are never compacted, however big they are (`ChatContextAccumulator.swift:127,135`). The current turn's tool loop can keep growing until it hits the limit and throws `contextLimit` (`ChatService.swift:2040-2055`). Fix: allow splitting *inside* a turn, but only at tool-group boundaries (after every response to one model message has arrived). Always keep the original user message word for word.
- **D5 (medium): protected constraints get pushed out.**
  - `cleaned` keeps only the newest 60 items (`.suffix(60)`, `ChatService.swift:2408-2413`).
  - The deterministic fallback files *every* user message as a constraint ("User said: …", `ChatService.swift:2351`).
  - Over repeated compactions, real constraints and approval decisions fall out first.
  - Fix: store approvals and denials (which already exist as tool or permission records) and explicitly pinned constraints separately. Inject them word for word and never summarize them.
- **D6 (medium): provider-reported usage is never used for budgeting.** `reconcileCompletedContextUsage` only updates the explanation text (`ChatService.swift:2120-2148`). Encrypted reasoning is counted by its JSON byte length (`ChatContextAccumulator.swift:196-197`), which can trigger compaction too early.
- **D7: no recovery when the provider says the context is too long.** I searched `Services/` for overflow handling and found none.
- **Minor:** `refreshCurrentContextEstimate` estimates with `ChatToolRegistry.all` instead of the tools actually sent (`ChatService.swift:2098`).

**Proposed implementation order:**
1. **Atomic checkpoint (D3)** plus a cooldown keyed by boundary ID.
2. **Portable summarizer input (D2):**
   - Render blocks as plain text: roles, tool name with shortened arguments and results, `attachment:<id> name`, `source:<id>`.
   - Exclude provider continuation data.
   - Cap the input at about 50% of the summarizer model's limit. If there's more, summarize in pieces: previous summary + next chunk.
3. **Fold dropped blocks into the checkpoint (D1).**
4. **Protected list of approvals and constraints (D5).**
5. **Usage anchor (D6):** save `{provider, deployment, system/tools fingerprint, last message ID, reported input tokens}`. The estimate becomes the anchor plus an estimate of only the new messages. Reset the anchor when any of those change. For reasoning items, budget from reported usage, not ciphertext length.
6. **Splitting inside a turn (D4).**
7. **One overflow retry (D7)**, allowed only if no visible text has streamed and no tool has run in this round. Shrink the budget to below what the provider reported, and check that the request actually got smaller.
8. **Later: native compaction (Azure and OpenAI only).** Store it as a cache next to the portable checkpoint, keyed by provider and deployment, and throw it away when the user switches provider. The Azure page I checked confirms server-side `context_management` works with `store=false`.
9. **Manual "Compact" button** with before and after token numbers.

## 2. Azure: findings

- **The routing fix is correct.** The Azure adapter sends `model` = the deployment name, `store:false`, encrypted reasoning, and `parallel_tool_calls` (`ChatModelProxy.swift:2011-2023`), to `/responses` with an `api-key` header (`ChatModelProxy.swift:1991-1997`). The new contract test checks exactly this (diff lines 335-370). Microsoft's Responses page lists `gpt-6.1-sol` (version 2026-09-29).
- **A1 (defect, medium): metadata can belong to the wrong model.** In `RuntimeModelCatalog.resolution` (`RuntimeModelCatalog.swift:151-178`), when Azure reports a model like `gpt-6.1-sol` that has no models.dev entry, the lookup falls back to the *slug's* record (`gpt-5.6-sol`). Then:
  - The descriptor and price come from GPT-5.6.
  - The ID is labeled `gpt-6.1-sol` (lines 167-173).
  - If there's no record at all, `ChatPricingCatalog` still prices the legacy slug at GPT-5.6 rates (`AIProviderSettings.swift:481-499`).

  This mostly affects existing users who never edit the default slug, which is `gpt-5.6-sol` (diff line 78). Fix: if the reported model doesn't match the slug and has no record, use the cautious defaults (50k limit, unknown price) and show "Configured slug X; Azure reports Y".
- **A2 (minor):** the display name is now the deployment name, so an empty deployment produces the error "Configure the  deployment name." with a blank gap (`ChatModelProxy.swift:799-804`, `AIProviderSettings.swift:369`). Use the slot name ("Smart"/"Fast") instead.
- **A3 (minor):** slugs are only trimmed, not lowercased (`RuntimeModelCatalog.swift:303-309`), so typing `GPT-6.1-Sol` misses the models.dev lookup. Also, unknown slugs inherit `supportsImages/PDFs/WebSearch: true` from `conservativeCapabilities` (`AIProviderSettings.swift:323-333`), which is optimistic.
- **A4:** the connection test sends text only, so it can't catch the tools + reasoning error (the live test's own comment admits this). Owner decision: add a request that declares one tool but doesn't run it.
- **Generic provider protocol:** don't send `reasoning_effort: none` automatically. That silently changes model behavior, and some servers reject unknown fields. Do two things:
  1. Now: show a non-blocking banner when the generic base URL matches an Azure host.
  2. Later: add an explicit "API: Chat Completions / Responses" setting that reuses `OpenAIResponsesChatModelProxy` with Bearer auth. Gateways differ on support for `include: reasoning.encrypted_content`, so test that per endpoint.

## 3. Finishing runs after leaving the app

- **Existing behavior:** backgrounding cancels the task and marks the run interrupted (`ChatService.swift:846-859`).
- **B1 (possible defect, verify):** line 858 resolves a pending approval as `.denied`. If that denial gets persisted as a tool result, the resumed model will believe the user refused. Record it as "awaiting approval (interrupted)" instead.
- **Execution vs display:**
  - A Live Activity only *shows* status. It doesn't let the app run.
  - `BGContinuedProcessingTask` is the execution API. As I understand it from WWDC25, it must be submitted from a user action while the app is in the foreground, it must report real progress, and the user or system can cancel or expire it. I couldn't load Apple's doc pages (they render with JavaScript), so check the submission strategy and progress rules on a device.
- **Honest progress for open-ended AI work:** use `maxToolIterations` (`ChatService.swift:1054`) as the total and count finished rounds: "Round 3 of up to 8 · Waiting for model…". Jump to done when the run finishes. Never estimate output length.
- **Lock screen and HealthKit:** HealthKit data is protected while the device is locked, so reads and writes can fail. Treat those as "pause and retry later", not as empty data.
- **Exactly-once writes:**
  1. Before running a write tool, save an intent record keyed by the provider's call ID.
  2. Save the journal entry and a "committed" marker in the same SwiftData save.
  3. On resume, skip any call ID that's already committed.
- **Provider background mode:** OpenAI's guide (verified) says response data is kept on disk for about 10 minutes for polling, ZDR projects run with `store=false`, and you can only resume a stream if the request was created with `stream=true`, using the `sequence_number` and `starting_after` cursor.
  - I could **not** confirm the Azure `store:true` requirement on the Microsoft page I fetched. Treat the research note's claim as unverified until someone finds it.
  - Remote completion also never runs local tools, so this only finishes *one* model call.
- **Force-quit:** never promise that a run survives it.

## 4. Apple Intelligence: critique

- **Confirmed in code:** at a 4,096-token limit, the output reserve is 2,048, the tool reserve is 4,000, and the history allowance comes out as `max(4096, …)` = 4,096. So the reserves are ignored (`ChatContextAccumulator.swift:112-117`). The note is right about this.
- **Missed by the note:** checkpoints can hold up to 60 items × 500 characters per field (`ChatService.swift:2400-2413`), which is far more than 4K tokens. The existing summarizer would also run on the same small model. "Reuse checkpoints" won't work without a much smaller schema.
- **Disagreement:** ship an explicit "On-device" provider first. "Automatic" selection adds migration and trust questions, and the note's own rule 4 already admits that.
- **Unverified (pages wouldn't load for me):** token counting arriving in iOS 26.4, PCC's 32K context and quotas, and ImageCreator no longer working on iOS 27. Don't put these in product copy until someone confirms them.
- **For scanning on iOS 26.2,** try Vision OCR plus deterministic parsing of the nutrition label before using the LLM.

## Acceptance tests to add

- Switching from 922k to 50k compacts in chunks, with no summarizer request over budget.
- A failed save leaves the previous checkpoint active.
- Trimmed blocks leave a stub that can be retrieved.
- A single huge tool-loop turn compacts at tool-group boundaries.
- Approvals survive three compactions.
- After an overflow retry, no write is duplicated.
- An Azure-reported model that differs from the slug falls back to unknown limits and price.
- Backgrounding during an approval prompt never records a denial.
- A resumed write is skipped if its call ID is already committed.

## Decisions for you (owner)

- Whether the connection test should declare a tool.
- Whether to opt in to Azure/OpenAI retention for background mode.
- Whether the app should send local notifications for pending approvals.
- Whether to add a generic protocol selector.
- Explicit vs Automatic on-device provider.

## Sources checked and limits

- **Fetched:** OpenAI's background-mode guide, and Microsoft's Azure Responses how-to (model list and compaction; the background section wasn't in what I got back).
- **Failed to load:** Apple's BackgroundTasks and FoundationModels pages.
- **Not checked by me:** Pi, OpenCode, and Hermes. Those comparisons come from the research note.
- **Not done:** no tests were run, so nothing here is verified as compiling or passing. Line numbers are from the worktree at `681dc2e`.
