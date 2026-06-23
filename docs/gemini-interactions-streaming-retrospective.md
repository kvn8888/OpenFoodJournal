# From GenerateContent to Interactions: Making Gemini Streaming Actually Visible

**Date:** 2026-06-23
**Branch:** `app-store`

OpenFoodJournal already had Gemini-powered food scans, but the user experience was still mostly a black box: the loading sheet sat on "Waiting for Gemini" until the final nutrition result appeared. This session migrated the app to Gemini's Interactions API, wired thought-summary events into the loading UI, and then fixed the more interesting bug: the stream was real, but my first parser accidentally batched it until the end.

## The Starting Point

The scan flow lived in `ScanService`. It built a Gemini request from a prompt plus one or more compressed JPEGs, sent it directly from the app using the user's BYOK API key, decoded JSON, then showed a review sheet before saving anything.

The old request shape was based on `generateContent`:

```swift
contents: [
    role: "user",
    parts: [
        text prompt,
        inline_data image
    ]
]
```

That worked for nutrition extraction, but it was the wrong surface for what we were trying to observe. The user wanted to see Gemini's thought summaries during the wait, not after the scan had already completed.

## Step 1: Moving to Interactions

I replaced the old generateContent request types with Interactions-native types:

```swift
private struct GeminiInteractionRequest: Encodable {
    let model: String
    let input: [GeminiContent]
    let tools: [GeminiTool]?
    let responseFormat: GeminiResponseFormat
    let generationConfig: GeminiGenerationConfig
    let stream: Bool
    let store: Bool
}
```

Interactions treats each input as a typed block, so image input moved from `inline_data` parts to first-class `image` blocks:

```swift
private enum GeminiContent: Codable {
    case text(String)
    case image(mimeType: String, data: String)
}
```

I kept the app's existing "latest alias only" model policy: `gemini-pro-latest` and `gemini-flash-latest`. That matters because the goal is to stay on Google's latest compatible model endpoint instead of hard-coding preview slugs that age out.

## Step 2: Preserving the Existing App Contract

The migration had to keep three app behaviors intact:

- Scans return a `NutritionEntry` for review, not an inserted database row.
- AI Search still uses Google Search grounding and validates nutrition before showing editable results.
- Gemini diagnostics still export safely without API keys or raw image bytes.

The Interactions API made AI Search cleaner. Instead of app-side search plumbing, the request can include a built-in tool:

```swift
let request = GeminiRequest(
    input: [.text(finalPrompt)],
    generationConfig: GeminiGenerationConfig(thinkingLevel: modelConfig.thinkingLevel),
    tools: [.googleSearch]
)
```

Usage metadata now drives the same cost and grounding logs as before. The important part is that this remained a transport change, not a journal-data change. Once the final JSON is decoded, the rest of the app still sees a normal `GeminiNutritionResponse`.

## Step 3: Showing Thought Summaries in the UI

Interactions streaming comes back as typed events. The loading overlay should update when a `step.delta` event has `delta.type == "thought_summary"`, and the final nutrition JSON should be accumulated only from `delta.type == "text"`.

The core routing ended up like this:

```swift
switch delta.type {
case "thought_summary":
    attempt.thoughtPartCount += 1
    recordThinkingTrace(text)
case "text":
    attempt.nonThoughtPartCount += 1
    jsonText += text
default:
    break
}
```

At this point the UI changed from a generic "Waiting for Gemini" state to a visible "Gemini is thinking" section with a summary count and the latest summaries. That was the right UI shape, but it exposed a deeper issue: the text appeared only at the very end.

## The Gotcha: The Stream Was Batched by My Parser

The first thing I tried was a UX dwell: after receiving a thought summary, hold the overlay briefly so the user could read it before the nutrition sheet appeared.

That was the wrong fix.

It made the late summary visible, but it did not solve the actual requirement: observability while waiting. Delaying the final result after the model is done is not streaming. It is just making the user wait longer.

The debug logs made the real root cause obvious:

```text
Gemini stream HTTP 200 model=gemini-pro-latest +4368ms
Gemini stream done model=gemini-pro-latest +17725ms
Gemini stream thought_summary #1 +17732ms
Gemini stream text_delta #1 +17733ms
Gemini stream complete ... firstThoughtMs=17732 firstTextMs=17733
```

`[DONE]` appeared before every parsed thought and text delta. That meant Gemini may have been streaming bytes, but the app did not process them until the end.

The mistake was assuming traditional blank-line-separated SSE frames. I collected `data:` lines and waited for a blank line before decoding them. The observed Interactions response behaved like newline-delimited `data:` JSON lines, so blank-line batching delayed every visible update until `[DONE]`.

The fix was to decode each `data:` payload immediately:

```swift
} else if line.hasPrefix("data:") {
    let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
    if payload == "[DONE]" { break }

    rawEventPayloads.append(payload)
    try await consumeGeminiInteractionStreamEvent(
        payload,
        eventName: currentEventName,
        attemptStartedAt: attemptStart,
        jsonText: &jsonText,
        attempt: &attempt
    )
    currentEventName = nil
}
```

That is the difference between "the API streamed" and "the app streamed." The UI only benefits if the client processes events as soon as they arrive.

## The Revision: Removing the Fake Streaming Delay

After the log proved the parser issue, I removed the artificial post-summary delay. I kept only a single `Task.yield()` after real thought-summary updates. That gives SwiftUI a chance to render actual early summaries without holding the final result screen hostage.

I also added focused DEBUG instrumentation:

- request start and payload size
- HTTP response timing
- each non-delta Interactions event
- each `thought_summary` delta with elapsed time and character count
- each `text` delta with elapsed time and accumulated JSON size
- final stream summary with first thought and first text timing

Those logs answer the next debugging question directly. If summaries still arrive near `[DONE]`, Gemini is batching for that request. If they appear earlier, the UI should now be able to show them while the request is still running.

## What Shipped

- `ScanService` now uses Gemini Interactions at `/v1beta/interactions`.
- Request bodies use typed `text` and `image` input blocks.
- `generation_config.thinking_summaries = "auto"` is enabled for scan/search calls.
- AI Search uses Interactions `google_search` tooling.
- API keys are sent via `x-goog-api-key`, not query strings.
- The loading overlays show `Thought summaries` instead of implying guaranteed smooth incremental updates.
- Gemini attempt logs now include first/last thought-summary and text-delta timings.
- Project skill notes now document the Interactions parser gotcha so future agents do not reintroduce blank-line batching.

## Verification

I verified the code with:

```bash
git diff --check -- OpenFoodJournal/Services/ScanService.swift .agents/skills/openfoodjournal/SKILL.md OpenFoodJournal/Views/DailyLog/DailyLogView.swift OpenFoodJournal/Views/FoodBank/AIFoodSearchView.swift
xcodebuild -quiet -project OpenFoodJournal.xcodeproj -scheme OpenFoodJournal -destination generic/platform=iOS -derivedDataPath /private/tmp/OpenFoodJournalDerivedData CODE_SIGNING_ALLOWED=NO build
```

The build passed. The user then confirmed the fix worked in the app.

## What's Next

The next useful improvement is not more UI delay. It is a small in-app debug export or Settings diagnostics view that summarizes the latest Gemini stream timeline: first HTTP byte, first thought summary, first text delta, done, total duration. That would let us diagnose model-side batching without scanning console logs every time.

---
Streaming is not a spinner feature. It is a parser contract.
