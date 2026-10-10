# Apple Intelligence as the no-key fallback

Research date: **2026-10-09**. Research only; no provider implementation, app build, simulator installation, credential access, or device test was performed. Source inspection used the task worktree based on `origin/testflight` `44cc46b`; the parallel Azure-model change subsequently advanced its HEAD to `349a4d2`.

## Recommendation

**Yes: offer a clearly labeled “Apple Intelligence · On device” Assistant when no conversation-provider key is configured and the system model is ready. Do not silently substitute it for the full cloud Assistant, photo scanning, or automatic icon generation.** Keep manual entry, saved-food logging, and deterministic nutrition calculations available regardless of AI readiness.

The safest first release is short, text-only help grounded in already-recorded journal data, initially read-only. The existing provider-neutral architecture is a useful starting point, but its key checks, context budget, tool execution, and attachment handling all need deliberate changes. This is not just another endpoint URL.

Important version distinction: the app supports **iOS 26.2+**. Apple’s current documentation also describes **iOS 27** features. A statement that Foundation Models can never understand images or access Private Cloud Compute would now be outdated; those capabilities must be version-gated and must not be promised to users on the app’s minimum OS. Apple explicitly dates the newer model/vision improvements to the iOS 27 generation and context inspection/token counting to iOS 26.4. [Apple WWDC26 overview](https://developer.apple.com/videos/play/wwdc2026/241/)

## Capability matrix

“Possible” below means supported by a documented API, **not validated for OpenFoodJournal’s accuracy or performance**.

| Feature | iOS 26.2 local baseline | iOS 27 additions | Product recommendation |
|---|---|---|---|
| Short text Assistant | Possible, on device, no API key or per-request cloud charge | Improved local model | Start with journal summaries and factual Q&A over app-provided data. |
| Context, meaning everything the model can consider at once | 4,096 tokens shared by instructions, schemas, tools, history, and output | Inspect runtime `contextSize`; WWDC example shows 8,192, while some current overview tables still say 4K | Do not hard-code 8K for every device. Use conservative 4K on 26.2 and runtime limits where supported. |
| Structured output | `@Generable`, guides, dynamic schemas | Still supported | Valid output shape does not guarantee correct nutrient values. Validate units, IDs, ranges, and arithmetic separately. |
| App tools | Supported; framework normally executes tools within its own response loop | More orchestration APIs | Preserve the app’s approval and durable write rules; do not introduce a second uncontrolled write loop. |
| Image understanding | No direct image-input path in the 26-era model | Image attachments and multimodal prompting | Separate opt-in scanning evaluation on 27; no automatic claim of nutrition-extraction parity. |
| PDF input | No documented direct PDF attachment path established in this research | Image attachments are documented, not a blanket native-PDF contract | Extract text with PDFKit; OCR or render scanned pages separately. Preserve page/source evidence and disclose limitations. |
| Web research | No built-in free web-search service supplied by the baseline local model | Custom tools remain possible; PCC is not itself a web-search entitlement | No-key local mode must not claim live web research. Existing keyed research providers remain separate. |
| Apple cloud model | Not available through the 26.2 Foundation Models baseline | `PrivateCloudComputeLanguageModel`: 32K context, reasoning, network, managed entitlement, daily quotas | Separate explicitly labeled cloud option, not the first local fallback. |
| Text emoji selection | Possible from a food name | Possible | Small, separately validated feature; a static icon/emoji is also a reliable no-key default. |
| Generated food icon images | Separate Image Playground APIs, not Foundation Models text output | Old non-UI `ImageCreator` no longer works on 27; system sheet is the replacement | Keep BYOK automatic icons or add a user-invoked “Create icon” sheet; do not build a new automatic backfill on ImageCreator. |

Sources: [26-era framework capabilities and offline behavior](https://developer.apple.com/videos/play/wwdc2025/360/), [context accounting](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window), [guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation), [tools](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling), [iOS 27 image prompting](https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting), [PCC availability and quotas](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute), [ImageCreator discontinuation](https://developer.apple.com/news/?id=dz9wvq0r).

## Availability and privacy: no key does not mean ready

The app’s iOS version is only one requirement. Apple Intelligence requires eligible hardware: for this iPhone app, iPhone 15 Pro/Pro Max and supported later models, not every iPhone that can run iOS 26. The user must have Apple Intelligence enabled and its model assets ready. A language change, downloads, unavailable storage, or disabling Apple Intelligence can make a formerly working feature unavailable. Do not request an API key as the remedy for every local-model failure. [Apple device/language/region requirements](https://support.apple.com/en-us/121115), [model availability checks](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models), [assets unavailable error](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror/assetsunavailable(_:))

Check `SystemLanguageModel.default.availability` before use and again after foregrounding/settings changes; still handle errors during a request. Distinguish `deviceNotEligible`, `appleIntelligenceNotEnabled`, and `modelNotReady`, with an unknown-state fallback. “Model not ready” is not a precise download-progress API: show “Apple Intelligence is not ready yet,” not a fabricated percentage. Offer retry, setup guidance, manual entry, or an explicitly selected configured provider. The app cannot silently enable system AI for the user. [Unavailable reasons](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum/unavailablereason)

Use `supportsLocale(_:)` and `supportedLanguages`, and handle unsupported-language errors; do not copy a current language list into a permanent app allowlist. Language support varies by OS and model generation. Apple’s September 2026 support page describes iOS 27 and should not be mistaken for a complete 26.2 guarantee. That page also documents China mainland restrictions and differences among regions/features. Use system availability as the operational source of truth rather than guessing from GPS or an iPhone model name. [Language handling](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models), [current regional requirements](https://support.apple.com/en-us/121115)

Once assets are ready, **local inference works offline**. That does not make the entire app offline-only: CloudKit transcript sync, optional Turso mirroring/diagnostics, Open Food Facts requests, URL fetching, and independently enabled search tools can still use the network. The UI should say “AI response generated on device,” not “nothing ever leaves your phone.” PCC is explicitly network-based, has a separate availability check, requires an approved managed entitlement, and applies daily user quotas. This research did not request that entitlement or verify account eligibility. [On-device behavior](https://developer.apple.com/videos/play/wwdc2025/286/), [PCC requirements](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute)

## What the current source actually does

No Foundation Models or Image Playground integration was found in the inspected production source.

| Existing code | Consequence for a local provider |
|---|---|
| [AIProviderSettings.swift](../OpenFoodJournal/Models/AIProviderSettings.swift), `AssistantProvider`, `AIProvider`, and `FoodIconImageProvider` | Assistant, scans, and images are already separate selections. Add local Assistant independently; do not repoint all three together. |
| [ChatModelProxy.swift](../OpenFoodJournal/Services/ChatModelProxy.swift), `ChatModelProxy.streamTurn` and `ConfiguredChatModelProxyFactory.make` | Good adapter boundary, but factory configuration currently requires a nonempty provider API key. Local construction must bypass that requirement honestly, not supply a fake key. |
| [ChatService.swift](../OpenFoodJournal/Services/ChatService.swift), `hasAPIKey` and run setup | The current check means “the selected provider has a key,” not “no keys exist anywhere.” Run setup independently rejects missing credentials. Replace these with provider-aware readiness. |
| [ChatView.swift](../OpenFoodJournal/Views/Chat/ChatView.swift), `missingKeyBanner` and file importer | Missing-key copy and attachment controls must follow the effective provider’s capabilities. Preserve unsupported uploads; never silently drop them from the prompt. |
| [ChatContextAccumulator.swift](../OpenFoodJournal/Services/ChatContextAccumulator.swift), `plan` | It reserves at least 2,048 output tokens and 4,000 tool tokens, yet floors history admission at 4,096. That arithmetic is inappropriate for a 4,096-token total window; merely changing the model limit is insufficient. |
| [ChatService.swift](../OpenFoodJournal/Services/ChatService.swift), `runTurn`, `systemPrompt`, `preparedContext` | Every request currently receives `ChatToolRegistry.all`; the system prompt includes today's entries and says PDFs/images can be analyzed directly. Build a compact, capability-specific local request instead. |
| [ChatToolRegistry.swift](../OpenFoodJournal/Services/ChatToolRegistry.swift) | Read tools and approval-gated writes are already classified. Start with a small read-only subset and keep deterministic arithmetic in Swift. |
| [ScanService.swift](../OpenFoodJournal/Services/ScanService.swift), `scan`, ingredient extraction, icon generation | Photo/label/OCR paths currently send images to keyed providers. Automatic icons have their own backend and queue. Neither becomes local just by adding an Assistant provider. |

The app’s durable transcript, context checkpoints, source artifacts, and write-execution records should remain the source of truth. A framework session is a temporary view of the relevant context, not a replacement database. Switching devices/providers must not replay a completed write or discard original messages. The existing eight-turn bound, cancellation, and suspended-run recovery also need to cover local work; an on-device model does not grant unlimited background execution.

## Provider selection rules

Add explicit selection intent: **Automatic / Apple Intelligence on device / chosen cloud provider**. Preserve existing users’ deliberate provider choices during migration.

1. **Explicit local:** stay local even if keys exist. If unavailable, explain why and offer choices; do not silently upload journal data to a cloud model.
2. **Explicit cloud:** a missing key, invalid key, network failure, rate limit, or exhausted quota is a configuration/runtime error. Offer “Use on-device Assistant” explicitly; do not silently change the model midway through an action.
3. **Automatic, no conversation-provider credentials:** use local only if ready and the request fits the advertised local feature set. Persist the effective provider/capabilities for that run.
4. **Automatic, some credentials exist:** a stray key does not authorize sending data to its provider. Preserve the established configured selection or ask the user to choose; do not select a random provider.
5. **Search keys and icon/scan credentials:** evaluate independently. A Tavily key alone does not make an Assistant model configured. A Gemini key can serve multiple roles, so define availability per feature rather than “any secret exists.”

Treat credentials as absent, present, or temporarily unreadable where the Keychain API permits that distinction. Never read or print secret values for routing diagnostics. “No key” is not the same as a failed authentication request.

## Adapter and safety design

For an initial local adapter, consider **guided action selection**: ask the model for either a final response or a small typed tool request; return that through `ChatModelTurn.calls`; let the existing coordinator execute and persist the tool, then prompt again with the result. Apple explicitly recommends generating tool arguments in one session, executing in app code, and processing results in another when context is tight. This is a design proposal requiring a prototype, not an already-proven adapter. It preserves the app’s single approval/write boundary more naturally than allowing a separate framework-owned loop to mutate SwiftData. [Context/tool guidance](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)

Native `Tool` wrappers are also possible, but the framework can call them repeatedly and concurrently within one response. A later integration must bridge every call through existing approvals, stable call IDs, idempotency records, cancellation, and iteration limits. Do not use tool errors or transcript rollback as proof that a database write never happened. [Tool execution behavior](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling)

Use `streamResponse` snapshots as cumulative visible content, not appended text deltas; otherwise text will duplicate. Map cancellation to the existing task/run lifecycle, test interruption while generating and awaiting approval, and do not resume writes from partial structured output. Do not manufacture HTTP status codes, provider request IDs, reasoning text, or exact token usage for local calls. On older OS versions label estimates as estimates; local cloud-inference charge is zero, not a measurement of battery cost. Framework cancellation latency and background behavior remain **unverified until device testing**. [Response-stream snapshots](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/responsestream)

Keep default safety guardrails and the existing non-medical scope. Nutrition journals may contain weight-loss, disease, or eating-disorder topics that trigger refusals. Handle those gracefully; do not retry with rewritten instructions to evade safety checks or silently switch providers to obtain a refused answer. Apple prohibits dangerous outputs and unsupervised consequential decisions in high-risk areas and prohibits guardrail circumvention. For this app, local mode should explain recorded facts, not diagnose, prescribe diets for diseases, guarantee allergen safety, or make unsupported claims about calories from a photograph. [Apple acceptable-use requirements](https://developer.apple.com/apple-intelligence/acceptable-use-requirements-for-the-foundation-models-framework/), [safety and refusals](https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output)

## Phased implementation proposal

1. **Readiness and honest defaults:** add selection intent and a testable availability service, provider-aware UI, and migration rules. Keep existing BYOK behavior unchanged for explicit users.
2. **Small local Assistant:** implement a text-only adapter; compact prompts; three to five relevant read tools at most; deterministic totals; a true shared 4K budget with output/tool headroom. Reuse checkpoints without deleting history. Record OS/runtime capabilities for troubleshooting.
3. **Reliability before writes:** verify streaming, refusal, context recovery, device changes, cancellation, and lifecycle behavior. Only then add writes via the existing approval/idempotency pipeline. Require no unintended or duplicated writes in the test suite.
4. **Separate label/PDF experiment:** on 26.2 use Vision OCR/PDFKit extraction followed by small structured text extraction; require user review and preserve unreadable/missing values rather than inventing them. OCR is not food-photo understanding. On 27, evaluate native vision against the same labeled dataset before offering it as an explicit scan option.
5. **Optional newer features:** evaluate PCC eligibility and privacy copy as a separate cloud choice. For icons, use static/emoji fallback or explicit Image Playground UI; retain BYOK for automatic batches. No new dependency on discontinued ImageCreator. [Apple migration notice](https://developer.apple.com/news/?id=dz9wvq0r)

## Required verification matrix

| Test group | Must prove before shipping |
|---|---|
| Selection and migration | New no-key install chooses ready local mode; existing explicit cloud choice remains; explicit local never uploads to cloud; stray search key does not change model choice; missing/invalid/unreadable credentials remain distinct. |
| Availability | Eligible/ineligible hardware; AI disabled; downloading/not-ready; settings changed mid-request; unsupported locale; unknown unavailable reason; offline after download versus before readiness. |
| Version contracts | iOS 26.2 text-only limits; 26.4+ runtime token counting where available; 27 vision/PCC behind version checks; no compile/runtime dependency on 27-only APIs in baseline execution. |
| Context | Long journal day; long chat; large tool schema/results; non-Latin text; complete-turn compaction; recovery below the actual context limit including output; original transcript unchanged. |
| Tools and writes | Correct read arguments and grounded answer; unknown/malformed tool calls rejected; approval denied/accepted; cancellation before/after commit; restart/retry causes no duplicate nutrition or HealthKit writes. |
| Streaming and lifecycle | No duplicated cumulative text; partial output never treated as completed action; first-response delay; concurrent sends; background/foreground; device lock; thermal/memory pressure; no promise of uninterrupted background work. |
| Health/safety | Ordinary nutrient summaries work; medical/eating-disorder questions and guardrail errors get safe, comprehensible responses; malicious page/OCR/tool text cannot bypass approvals. |
| Attachments and scans | Unsupported photo/PDF is clearly explained and retained; OCR preserves units and serving basis; unreadable numbers remain unknown; no fabricated missing ingredients; user review before save. |
| Privacy and accounting | No model network call in local-only tests; separately enabled sync/research disclosed; redacted diagnostics; zero cloud inference cost distinguished from unknown token counts; local-to-cloud switch requires clear user intent. |
| Device quality | Real supported iPhone measurements for latency, battery/thermal behavior, structured extraction accuracy, and regression after OS model updates. No simulated or source-only check substitutes for this. |

**Decision:** proceed with a scoped prototype of no-key, read-only local Assistant help if desired. Do not advertise “the full app works with Apple Intelligence for free” until each separate scanning, research, and image feature has its own implemented and verified contract.
