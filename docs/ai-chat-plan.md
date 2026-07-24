# AI Chat ("Assistant") — Feature Plan

*Planned 2026-07-19. Status: Phase 1 (skeleton — models, 5th tab, thread list, streaming chat, Settings model picker) implemented 2026-07-19. Phases 2-4 pending.*

*Implementation notes vs. original plan: models use the repo's `-latest` alias policy (`gemini-flash-latest`/`gemini-pro-latest`), not dated preview slugs; chat also honors the OpenRouter provider setting (chat completions streaming) since the app gained an `AIProvider` abstraction; chat uses `streamGenerateContent?alt=sse` rather than the Interactions API used by scans because `contents` replay + function calling is the documented generateContent path.*

## Concept

An agentic AI chat, inspired by Bevel Intelligence / Claude Code / Codex: a Gemini-powered
agent with function-calling tools that give it CRUD access to the user's nutrition data,
gated by user-surfaced permission prompts. Runs entirely on-device against SwiftData via
the existing BYOK Gemini REST integration — no server.

## Decisions (locked with user)

| Question | Decision |
|----------|----------|
| Capabilities | All four: journal analysis, conversational logging, coaching/suggestions, general Q&A |
| Entry point | 5th tab ("Assistant", sparkles icon) |
| Persistence | Persistent threads, CloudKit-synced `@Model`s |
| Write permissions | Per-action Allow/Deny card, every time (doubles as review-before-commit) |
| Streaming | Yes — `streamGenerateContent` SSE |
| Auto-context | Today's summary + goals in system prompt; everything else via tools |
| Thread UX | Thread list + individual chats (opens most recent; "+" for new; auto-generated titles) |
| Tool visibility | Inline activity chips for reads ("Read journal: Jul 12–18"); permission cards for writes |
| Model | User-selectable in Settings: Fast (gemini-3.1-flash-preview) / Smart (gemini-3.1-pro-preview), with 2.5 fallbacks like ScanService |

## Architecture

### New SwiftData models (CloudKit-safe: all defaults, optional relationships, no uniques)

- **`ChatThread`** — `title: String = ""` (auto-generated after first exchange), `createdAt`,
  `updatedAt`, `messages: [ChatMessage]? = []` (cascade delete). `safeMessages` computed
  property per the existing pattern.
- **`ChatMessage`** — `role: String` ("user" / "model" / "tool"), `text: String = ""`,
  `toolPayload: Data? = nil` (serialized function call / result / permission state),
  `timestamp: Date`, optional inverse relationship to thread.

### `ChatService` (`@Observable @MainActor`, sibling of ScanService)

Agent loop:

```
send(userText) →
  build request: system prompt + tool declarations + last ~30 messages replayed
  → POST streamGenerateContent (SSE via URLSession.bytes)
  → stream text deltas into a live bubble
  → on functionCall:
      read tool  → execute against NutritionStore/SwiftData, append activity chip,
                   feed functionResponse back, continue loop
      write tool → append pending permission card, SUSPEND loop;
                   on Allow: execute, feed result back, continue
                   on Deny:  feed denial back, continue (model acknowledges)
  → loop until plain-text final response
```

- API key from `KeychainService.geminiAPIKey` (same as ScanService).
- Model from `@AppStorage("chat.model")` (fast/smart); 500/503 fallback to
  gemini-2.5-flash / gemini-2.5-pro, mirroring `GeminiModelConfig`.
- System prompt includes: current date, today's macro summary, user goals, and
  Guideline 1.4.1 instructions (cite sources, no medical claims, recommend
  professionals for medical questions).

### Tool catalog

| Tool | Type | Backed by |
|------|------|-----------|
| `get_daily_summary(date)` | read | `NutritionStore.fetchLog` + `UserGoals` |
| `query_entries(startDate, endDate, meal?)` | read | `NutritionStore.fetchLogs` |
| `search_food_bank(query)` | read | SavedFood fetch |
| `get_goals()` | read | `UserGoals` |
| `get_active_energy(date)` | read | `HealthKitService` (if authorized) |
| `log_entry(draft)` | **write** | `NutritionStore.log` |
| `update_entry(id, changes)` | **write** | `NutritionStore.saveEntry` |
| `delete_entry(id)` | **write** | `NutritionStore.delete` |
| `save_food(draft)` | **write** | SavedFood insert |
| `update_goals(changes)` | **write** | `UserGoals` |

### UI

- **5th tab** in `ContentView`: "Assistant" (sparkles icon).
- **`ChatView`** — opens most recent thread. Message list (`List`, plain style per project
  conventions), streaming model bubble, read-activity chips, write permission cards
  (food name + macros + meal + date, Allow / Deny), Liquid Glass input bar.
- **Thread list** — toolbar button presenting past threads (title + relative date,
  swipe-to-delete); "+" starts a new thread.
- **Disclaimer footer** — persistent "AI-generated — not medical advice" caption linking
  to `HealthDisclaimerView`.
- **Settings** — new "Assistant" section: model picker (Fast / Smart). Reuses the existing
  Gemini API key; if no key saved, chat shows the same setup guidance as scanning.

### App Store considerations (Guideline 1.4.1)

- System-prompt citation/disclaimer instructions.
- Visible disclaimer footer in chat.
- All data writes require explicit user approval (permission cards) — no autonomous
  modification of health data.

## Implementation phases

1. **Skeleton** — models, 5th tab, thread list, plain streaming chat (no tools).
2. **Read tools** — agent loop with function calling, activity chips, today+goals context.
3. **Write tools** — permission cards, suspend/resume loop, review-before-commit.
4. **Polish** — auto-titles, Settings model picker, error/retry affordances,
   WhatsNewSheet entry, update project skill.

## Deferred (post-v1)

- Thread summarization for long conversations (v1 caps replay at ~30 messages).
- "Always allow" per-tool permission persistence.
- Proactive coaching (e.g., end-of-day check-ins).
- Offline queueing of unsent messages.

---

# v2 — Full Agent (planned 2026-07-19, implemented 2026-07-20)

*Status: all six phases implemented. Implementation notes vs. plan:*
- *Camera capture inside chat was deferred — attachments come from the photo
  library and the PDF file importer; the scan tab already covers camera.*
- *`GeminiScanLog` rows for chat were deferred (the log model is scan-shaped);
  chat usage does feed `GeminiCostAccumulator` with a labeled estimate
  (flash 0.30/2.50, pro 2.50/15.00 USD per 1M tokens).*
- *fetch_url PDFs persist as `ChatAttachment` rows on the tool message, so
  fetched documents survive thread resume and replay into context.*
- *Regenerate lives in the context menu of the last model bubble
  (Regenerate / with Fast / with Smart / Copy).*

Motivating use case: "Create a nutrition calculator for Wegmans subs" — the source is
a website that serves a PDF of a spreadsheet-style nutrition calculator. The assistant
fetches the PDF, parses it natively with the model, drafts a `SavedFood(kind: .calculator)`,
and the user reviews it in the existing calculator editor before saving.

## Decisions (locked with user)

| Question | Decision |
|----------|----------|
| Scope | Full agent: journal read/write tools + calculator CRUD + attachments + web search + regenerate, one release |
| Calculator review | Permission card's "Review & Save" opens `NutritionCalculatorEditorView` prefilled (same UX as OCR import) |
| URL handling | `fetch_url(url)` tool — on-device download, activity chip; no manual upload dance required |
| Regenerate | Context menu on last reply: Regenerate / Regenerate with Fast/Smart; old reply replaced |

## Tool catalog (v2 complete set)

**Read — auto-execute, rendered as activity chips:**

| Tool | Notes |
|------|-------|
| `get_daily_summary(date)` | totals + goal progress |
| `query_entries(startDate, endDate, meal?)` | raw entries for analysis |
| `search_food_bank(query)` | includes composites and calculators |
| `get_goals()` / `get_active_energy(date)` | goals, HealthKit burn |
| `list_calculators()` / `get_calculator(id)` | calculator reads |
| `web_search(query)` | grounded sub-request (see below) |
| `fetch_url(url)` | on-device download of PDF/HTML (see below) |

**Write — permission card required, every time:**

| Tool | Review surface |
|------|----------------|
| `log_entry(draft)` | inline card (name + macros + meal + date) |
| `update_entry(id, changes)` / `delete_entry(id)` | inline diff card |
| `save_food(draft)` | inline card |
| `update_goals(changes)` | inline diff card |
| `create_calculator(draft)` | card → **Review & Save** opens prefilled `NutritionCalculatorEditorView` |
| `update_calculator(id, changes)` | card → Review & Save opens prefilled editor |

Calculator drafts reuse `CalculatorIngredientDraft` / `CalculatorPortionDraft`
(already proven by the OCR import path in ScanService).

## Key mechanics

**Agent loop** — `streamGenerateContent` with `functionDeclarations` (Gemini) /
`tools` param with streamed `tool_calls` deltas (OpenRouter). Loop: stream → on
functionCall, execute (reads) or suspend on a `CheckedContinuation` until the
permission card resolves (writes) → append functionResponse → continue until a
plain-text turn. Tool calls/results persist as `ChatMessage(role: .tool)` with
`toolPayload` and are replayed into context on thread resume.

**`web_search(query)`** — declared as a function tool and executed through the
provider-neutral `ChatWebSearchProviding` interface. Users can choose the
selected model provider's native grounding (Gemini Google Search, OpenRouter
web plugin, or Azure web search), Tavily, or Parallel independently of the
conversation model. The provider-neutral request includes a self-contained
objective and optional 2-3 concise keyword queries. Tavily returns structured
snippets; Parallel returns objective-focused excerpts and keeps related calls
under one agent-run session ID. The Assistant synthesizes either result in its
next normal model turn. Search sources persist as durable artifacts. `fetch_url`
remains a separate protected on-device fetch and no research request silently
falls back to another provider.

**`fetch_url(url)`** — on-device `URLSession` download. PDFs/images can't ride in
a `functionResponse` (JSON only), so binary content is injected as a synthetic
user-turn `inline_data` part (`application/pdf`, inline cap ~15MB) with the
functionResponse carrying metadata (content type, size, status). HTML is
tag-stripped to text and returned in the functionResponse, truncated.

**Attachments** — input bar gains an attach menu: photo library, camera, file
importer (PDF). New `ChatAttachment` `@Model` (CloudKit-safe): `data` with
`@Attribute(.externalStorage)`, `mimeType`, `filename`, optional relationship to
`ChatMessage` (a message can carry several). Images resized to max 1200px JPEG
(ScanService parity). Bubbles render thumbnails; PDFs show a file chip.

**Regenerate** — context menu on the last model bubble: Regenerate, Regenerate
with Fast/Smart, Copy. Service deletes everything after the last user message
(model reply + trailing tool messages) and re-streams, optionally overriding
`ChatModelPreference` for that one request.

**Cost tracking** — chat replies parse usage metadata and feed
`GeminiCostAccumulator` + a `GeminiScanLog` row (new operation case, e.g.
`.chat`), matching scan/search diagnostics. PDFs + tool loops make chat
meaningfully more expensive per message; the user should see it in the existing
cost UI.

## Implementation phases (v2)

1. **Agent loop core** — function-calling stream parsing (both providers),
   tool dispatch, `ChatMessage(role: .tool)` persistence, activity chips,
   journal + calculator read tools.
2. **Write tools** — permission cards with continuation suspend/resume,
   log/update/delete entry, save_food, update_goals.
3. **Attachments** — `ChatAttachment` model, attach menu UI, multimodal
   request encoding (Gemini inline_data / OpenRouter content parts).
4. **Web** — `web_search` grounded sub-request + `fetch_url` with PDF
   injection. Wegmans end-to-end test happens here.
5. **Calculator CRUD** — create/update tools + prefilled
   `NutritionCalculatorEditorView` review flow.
6. **Polish** — regenerate + model picker, cost accumulation, What's New
   entry, skill/docs update.

---

# Future roadmap (v3+ candidates, sketched 2026-07-19)

Not committed — grouped by theme, roughly in value-per-effort order.
Sequencing rationale: memory (v3) changes how the app feels day-to-day;
proactive check-ins (v4) change retention but carry the most tonal/App Store
risk; v5 items are additive and can be cherry-picked anytime.

## v3 — Memory & trust

- **Assistant memory** — persistent store of user facts the agent reads/writes
  with permission ("lactose intolerant", "hates cilantro", "marathon training
  until October"). Injected into the system prompt every conversation. The
  single biggest quality jump after tools.
- **Per-tool "always allow"** — permission cards grow an "Always allow X"
  option stored in `Preferences`, with a management list in Settings.
  Destructive tools (delete_entry, update_goals) remain always-prompt.
- **Thread summarization** — replace the 30-message replay cap with
  compaction: older messages summarized into a rolling context block so
  months-long coaching threads stay coherent and cheap.
- **Scan-in-chat** — a `scan_food_photo` tool routes chat photo attachments
  through the existing ScanService pipeline, unifying the two AI surfaces.

## v4 — Proactive coaching

- **End-of-day check-in** — local notification ("42g short on protein with
  ~600 kcal left — want ideas?") deep-linking into a chat thread with that
  context preloaded.
- **Weekly review** — generated Sunday summary thread (trends, wins, one
  suggestion) built from `fetchLogs` + the nutrient breakdown data behind
  History.
- **Shelf synergy** — `ShelfRecommendationEngine` picks candidates
  deterministically; the agent explains *why* in plain language. Math for
  trust, LLM for narrative.
- **Risk notes** — proactive health nudges need the same 1.4.1 disclaimers,
  and notification copy must never feel judgmental (eating-disorder
  sensitivity). This phase needs a deliberate tone pass before shipping.

## v5 — Platform reach

- **App Intents / Siri** — "Log two eggs and toast" runs the conversational
  logging tool headlessly with a confirmation sheet. Unlocks Shortcuts, the
  Action Button, and widget entry points.
- **Voice input** — speech-to-text in the chat input bar via
  `SpeechTranscriber`.
- **On-device fallback** — Apple Foundation Models for simple Q&A and logging
  parses when offline or keyless, so BYOK stops being a hard gate for the
  basic experience.

## Parking lot

- Offline message queueing.
- Multi-user / family sharing via CloudKit shared database.
- Exportable "nutrition report for my dietitian" generated by the agent.
- Recipe URL → composite food import (nearly free once v2's `fetch_url` +
  CRUD machinery exists).

---

# Build 7 — Assistant Runtime Hardening (implemented 2026-07-21)

Epic #25 workstreams 5-12 are implemented on top of the provider portability,
durable context/source, approval, and exactly-once foundations. The runtime now
persists each send synchronously before provider work, coordinates one app-wide
persisted run, enforces the short deadline/retry policy, suspends safely across
backgrounding, executes independent reads in parallel, and records redacted
latency plus per-round/daily usage and cost. The Assistant surfaces truthful
phase/activity, Stop/Retry/Continue, grouped tool state, stable context metrics,
and completed-run details without fabricating reasoning or progress.

See [Build 7 — Assistant Runtime Hardening](build-7-assistant-runtime-hardening.md)
for verification evidence and the unexecuted internal TestFlight checklist.
