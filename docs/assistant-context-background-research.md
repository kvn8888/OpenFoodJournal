# Azure model selection, context compression, and background completion

Research date: 2026-10-09. App baseline: TestFlight commit `44cc46b`.
Azure settings changes in this branch are implemented locally. Compression and
background execution below are recommendations, not shipped behavior.

## Why the HTTP 400 happened

The reported error names `/v1/chat/completions`: function tools combined with
reasoning are unsupported there for the selected `gpt-6.1-sol` deployment.
OpenFoodJournal's **OpenAI-compatible** Assistant provider routes through
`MuseSparkChatModelProxy`, which unconditionally appends `chat/completions`.
The dedicated Azure provider uses `OpenAIResponsesChatModelProxy`, appending
`responses` and authenticating with `api-key`.

The compatible request builder does not explicitly serialize `reasoning_effort`.
The error establishes the rejected combination but not where the effective
reasoning setting originated. We did not inspect the phone's exact request or
run a paid reproduction with the owner's credential. Do not assert that the
app explicitly set a particular effort value.

The architectural mistake was conflating an editable model/deployment with a
fixed two-model menu, which pushed users into an adapter with a different wire
protocol. URL compatibility does not establish tools/reasoning compatibility.

### Implemented change

- Azure Fast/Smart slots each have an editable base-model slug and deployment.
- Legacy Sol/Terra storage keys remain stable, preserving saved configuration.
- Both primary and fallback selection use the configured slug. Only the
  deployment is sent as the request's `model`; the slug drives metadata lookup.
- Unknown slugs start at the existing conservative 50k limit and unknown pricing;
  models.dev can supply metadata. No new model is assigned GPT-5.6 prices/limits.
- Non-secret slugs round-trip through JSON backups with legacy defaults.
- Official Foundry `*.services.ai.azure.com` resource URLs are accepted alongside
  existing Azure hosts; HTTPS, path, credential, public-address, and redirect
  checks remain in force.
- Settings explains that the compatible provider uses Chat Completions and
  directs Azure users to Azure OpenAI. It does not silently disable reasoning,
  transfer saved keys, or switch providers.

Microsoft documents deployment names in the request and the Responses route,
including GPT-6.1 Sol support. Its endpoint guide documents both resource host
formats. [Responses](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/responses),
[resource endpoints](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/endpoints).

## Compression already present in OFJ

`ChatContextAccumulator` and `ChatService.preparedContext` already support:

- 50k/200k/model-limit budgets, an 80% compaction trigger, and output/tool reserves.
- Structured rolling checkpoints, complete user/tool-turn boundaries, retained
  transcripts, durable sources, and `read_conversation_source` for retrieval.
- A deterministic fallback and visible warning when summarization fails;
  complete-turn pruning and rejection when the remaining input cannot fit.

The gaps found in source are substantial:

1. Estimates count opaque encrypted continuation JSON as ordinary text. Byte
   length is not the model's underlying reasoning token count.
2. Actual usage is displayed/accounted but does not anchor subsequent budget
   estimates. The entire context is estimated again using three bytes per token.
3. `createCheckpoint` sends the old prefix directly to the model with a different
   system prompt and no tools. It has no dedicated summary-input size check or
   chunking, and includes native provider continuation items from that prefix.
4. The checkpoint save uses `try?`. Activating an unsaved checkpoint can make
   effective context disagree with durable state after a crash.
5. At least two blocks are retained, but a block can be an arbitrarily large
   user turn. There is no explicit recent-token budget or compression progress
   guard, and no dedicated one-shot provider-overflow recovery was identified.

## Lessons from current harnesses

| Harness | Observed approach | What OFJ should borrow |
|---|---|---|
| Pi | Uses reported usage plus estimates for the appended tail; reserves output space, keeps a token-bounded recent tail, stores an explicit kept boundary, and supports bounded overflow recovery. | Usage anchors invalidated by edits/model switches; explicit recent-tail budgets and one safe overflow retry. |
| OpenCode v2 | Specification preserves transcript plus a completed checkpoint and a serialized recent tail. Source bounds the summary request, serializes attachments as references, limits tool-output text, and commits completion only after a successful summary. | Separate portable summarization input from native replay; enforce a budget for summarization itself; activate checkpoints atomically. |
| Hermes | Documents provider-usage anchors, compression cooldowns, bounded recovery, and an optional rolling micro-compaction mode. | Avoid repeatedly summarizing the same failing or unchanged context; evaluate incremental summaries only after measuring cost and cache effects. |

Sources inspected: [Pi implementation](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/compaction/compaction.ts),
[Pi reference](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/compaction.md),
[OpenCode v2 specification](https://github.com/anomalyco/opencode/blob/dev/specs/v2/session.md),
[OpenCode core implementation](https://github.com/anomalyco/opencode/blob/dev/packages/core/src/session/compaction.ts),
[Hermes context guidance](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/context-compression-and-caching.md),
[Hermes micro-compaction](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/micro-compaction.md).
These are moving upstream references read on the research date; no dependency
on these projects is proposed. OpenCode's specification is design intent;
the inspected source establishes the narrower behaviors described above.

### Recommended compression workstream

1. Store a usage anchor tied to provider, model, request schema/system fingerprint,
   and transcript boundary. Estimate only appended content; invalidate after an
   edit, model change, checkpoint, or changed instructions/tools.
2. Treat opaque reasoning as opaque, preserving bytes for valid same-provider
   replay. Use provider usage for accounting rather than counting ciphertext.
3. Summarize a bounded portable transcript containing visible text, completed
   actions, approvals/denials, source IDs, and attachment references. Do not send
   opaque provider state to the summarizer or invent raw chain-of-thought.
4. Preserve a token-bounded tail of complete exchanges. Separate protected user
   constraints and durable approval records from lossy summaries. Re-fetch current
   journal facts instead of treating summarized nutrition as live database state.
5. Validate, save, and only then activate a checkpoint. A save failure leaves
   the old boundary active. Never delete original conversations or evidence.
6. Add a single context-overflow retry only before visible output/tool execution,
   with a measurable-reduction guard and failure cooldown. Keep hard-cap checks.
7. Add a manual Compact action and clear Info-sheet before/after accounting.

Acceptance cases: long tool-only runs; repeated compaction; large PDFs; huge
encrypted items; malformed/oversized summaries; failed saves; interrupted
summarization; provider/model switch; changed prompts; approval denial retention;
source retrieval after compaction; no duplicate writes after overflow recovery.

### Native Responses compaction is an optional optimization

OpenAI also documents `context_management` with `compact_threshold`, and the
standalone `/responses/compact` endpoint. These return opaque compaction items;
the standalone endpoint's returned window must be replayed intact. Server-side
compaction can use `store: false`. [OpenAI compaction](https://developers.openai.com/api/docs/guides/compaction).

OFJ should retain its portable checkpoint and original transcript as canonical
state. A provider-specific compacted window could accelerate same-provider
continuation, but cannot be the only saved representation if a user switches to
Gemini, Anthropic, or a local model. The current capability flag is not an
implementation of this API; adapters do not yet request native compaction.

## Completing work after leaving the app

Today `OpenFoodJournalApp` invokes `suspendForBackgrounding`, which saves a draft
and cancels the run's task immediately. Switching app screens is different from
backgrounding the application. The current Continue behavior is intentional.

### Apple execution versus display

ActivityKit displays status, but the Live Activity itself cannot access the
network. iOS 26's `BGContinuedProcessingTask` is the relevant execution API:
user-started foreground work can continue with networking, and the system
supplies a Live Activity with cancellation. Admission is conditional; expiration,
resource pressure, and force-quitting can end execution. Progress must be real.
The app's minimum iOS version supports this API, but streaming behavior and
indeterminate progress need a physical-device feasibility test before release.
[Apple continued processing](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados),
[ActivityKit constraints](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities).

Recommended first phase: register one continued-processing task per user-started
run; retain the current task while admitted; connect system cancellation to Stop;
persist safe boundaries on every completed round; save and suspend on expiration.
If admission fails, continue normally in foreground and show the existing
interrupted state upon backgrounding. Do not invent percentages for unknown
model output length. Pause for approvals rather than approving in the background.
Never promise completion after force-quit.

### Provider-side completion

Responses background mode can finish an individual model request remotely and
supports status retrieval and stream resumption. Persist response ID and stream
cursor before disconnecting. Current OpenAI documentation describes temporary
response storage for asynchronous retrieval, including account-specific retention
rules. Azure documents background mode too and flags a streaming performance
issue and explicitly requires `store: true`. That conflicts with OFJ's current
stateless Azure contract, so Azure background mode needs a deliberate opt-in
storage-policy change rather than silently changing the payload. Verify each
deployment's behavior and retention separately; don't infer Azure policy from
OpenAI's. [OpenAI background mode](https://developers.openai.com/api/docs/guides/background),
[Azure Responses](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/responses).

Provider-side generation does not execute OFJ's local journal/HealthKit tools
while the app is suspended. A completed remote response may still need tool
results before the overall task can finish. A fully independent agent would need
a server coordinator with carefully scoped data access, credentials, durable
approval handling, and push delivery. That is a larger privacy and infrastructure
decision, not a Live Activity feature.

### Background acceptance cases

- Home-screen switch, screen lock, and app navigation during text and tool rounds.
- Task admission failure, expiration, system cancellation, force-quit, relaunch.
- Lost connection after remote acceptance: retrieve the original response,
  don't create a second paid request just because the stream disconnected.
- Pending approval and uncertain write outcomes remain explicit on resume.
- No raw prompts, journal values, or reasoning in Lock Screen status by default.

## Verification of this branch

Added five offline regression tests (custom slugs/legacy slots, backup migration,
request wire contract, Foundry URL validation, and runtime metadata) and one opt-in live Azure
tools-and-result round trip. Existing signature and continuation suites remain.
The live test needs `OFJ_RUN_LIVE_CHAT_TESTS=1`, `OFJ_AZURE_MODEL_SLUG`,
`OFJ_AZURE_DEPLOYMENT`, `OFJ_AZURE_OPENAI_ENDPOINT`, and
`OFJ_AZURE_OPENAI_API_KEY`; absent credentials skip it.

Swift syntax parsing and whitespace checks pass locally. Full app compilation,
unit execution, live API verification, and device background tests are not yet
performed for this branch. The app's hosted Cloud CI runs the offline tests;
no local app build, simulator installation, or TestFlight release was performed.
