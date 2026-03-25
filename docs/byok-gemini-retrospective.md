# BYOK Gemini Migration: Killing the Server Proxy

**Date:** 2025-07-17  
**Branch:** `app-store`  
**Commit:** `35661c3`

## TL;DR

We removed the Express.js Render proxy server entirely from the iOS app's architecture and replaced it with direct REST API calls to Google's Gemini API. Users bring their own API key (BYOK), stored securely in the iOS Keychain. The result: zero server infrastructure, zero ongoing costs, zero cold-start latency from Render's free tier, and one fewer point of failure.

---

## The Problem

OpenFoodJournal's core value proposition is scanning food labels and photos with AI. The original architecture looked like this:

```
iOS App → multipart POST → Express.js on Render → @google/generative-ai SDK → Gemini API → JSON response → iOS App
```

This had several problems:

1. **Cold starts**: Render's free tier spins down after 15 minutes of inactivity. First scan after idle = 30-60 second wait.
2. **Double latency**: Image travels from phone → Render → Google, then response travels Google → Render → phone.
3. **Server maintenance**: Another thing to keep running, monitor, and pay for as usage grows.
4. **API key exposure risk**: API key lives in a server environment variable. If Render is compromised, the key leaks.
5. **App Store dependency**: Apple reviewers may flag an app that requires an external server for core functionality.

The fix was obvious in hindsight: call Google's API directly from the device.

---

## Research Phase: What Were the Options?

Before writing code, we evaluated three approaches:

### Option A: Firebase AI Logic SDK (~5-10 MB)
Google's official iOS SDK for Gemini. Handles auth, retries, streaming. But it adds a binary dependency, increases app size, and we'd still need either a Firebase project or API key management.

### Option B: On-device Gemini Nano (0 MB network)
Would be perfect — no API calls at all. But Gemini Nano is **Android-only** via ML Kit. Apple has no equivalent on-device model API (as of July 2025). Dead end.

### Option C: Direct REST API (0 dependencies)
Just `URLSession` + `Codable`. Build the JSON request manually, POST to `generativelanguage.googleapis.com`, parse the response. No SDK, no Firebase, no dependencies. The Gemini REST API is well-documented and stable.

**We chose Option C.** Zero dependencies aligns with the project's existing convention (no SPM packages at all), and the Gemini REST API is simple enough that a SDK wrapper adds complexity without meaningful value.

---

## Implementation

### 1. KeychainService — Secure Storage (New File)

The API key needs to persist across app launches but never appear in plaintext storage. iOS Keychain is the correct answer — it's hardware-encrypted, survives app updates, and integrates with the Secure Enclave on devices that have one.

```swift
struct KeychainService {
    static let serviceName = "k3vnc.OpenFoodJournal"
    static let geminiAPIKeyAccount = "gemini-api-key"
    
    static func save(_ value: String, for account: String) -> Bool {
        let data = Data(value.utf8)
        
        // Delete any existing value first (update = delete + add)
        delete(for: account)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
}
```

**Key decision: delete-then-add vs. SecItemUpdate.** The `SecItemUpdate` API is verbose and requires separate query/attribute dictionaries. Delete-then-add is two lines and handles both insert and update cases identically. For a single API key that changes rarely, the atomic operation difference is irrelevant.

**Why not `@AppStorage` or `UserDefaults`?** These store data in a plist that's readable by anyone with device access (jailbroken or backup extraction). Keychain items are encrypted at rest and protected by the device passcode. For an API key that could incur billing, this matters.

### 2. ScanService Rewrite — Direct Gemini REST

The original `ScanService` built a multipart form-data request with the image and metadata, sent it to the Render proxy, and parsed the JSON response. The new version builds a Gemini API request directly.

**Before (multipart to Render):**
```swift
// Old: Build multipart form data, POST to proxy
var request = URLRequest(url: URL(string: "\(proxyBaseURL)/scan")!)
let boundary = UUID().uuidString
request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
let body = buildMultipartBody(image: jpeg, mode: mode, boundary: boundary)
```

**After (JSON to Gemini):**
```swift
// New: Build JSON body with base64 image, POST directly to Google
guard let apiKey = KeychainService.geminiAPIKey else {
    throw ScanError.noAPIKey
}

let config = mode == .label ? GeminiModelConfig.labelScan : GeminiModelConfig.foodPhotoScan
let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(config.model):generateContent?key=\(apiKey)")!

let requestBody = GeminiRequestBody(
    contents: [GeminiContent(parts: [
        GeminiPart(text: prompt, inlineData: nil),
        GeminiPart(text: nil, inlineData: GeminiInlineData(
            mimeType: "image/jpeg",
            data: jpegData.base64EncodedString()
        ))
    ])],
    generationConfig: GeminiGenerationConfig(
        responseMimeType: "application/json",
        thinkingConfig: GeminiThinkingConfig(thinkingLevel: config.thinkingLevel)
    )
)
```

**The model configuration mirrors exactly what the server used:**

```swift
struct GeminiModelConfig {
    let model: String
    let thinkingLevel: String
    let fallbackModel: String
    
    // Fast OCR extraction — minimal reasoning needed
    static let labelScan = GeminiModelConfig(
        model: "gemini-3.1-flash-lite-preview",
        thinkingLevel: "MINIMAL",
        fallbackModel: "gemini-2.5-flash"
    )
    
    // Food estimation requires deep reasoning about portions, density, etc.
    static let foodPhotoScan = GeminiModelConfig(
        model: "gemini-3.1-pro-preview",
        thinkingLevel: "HIGH",
        fallbackModel: "gemini-2.5-pro"
    )
}
```

### 3. Handling Thinking Parts

When `thinkingLevel` is set to anything other than `"NONE"`, Gemini returns its chain-of-thought reasoning as additional `parts` in the response. The actual answer is always the **last text part**. This is easy to miss if you just grab `parts[0].text`:

```swift
// Wrong — this gets the thinking/reasoning text, not the answer
let text = response.candidates.first?.content.parts.first?.text

// Correct — skip thinking parts, grab the final text
let text = response.candidates?.first?.content.parts
    .last(where: { $0.text != nil })?.text
```

This was a subtle but critical detail. The server's `@google/generative-ai` SDK handles this automatically via its `.text` accessor, but with raw REST you're working with the raw parts array.

### 4. Fallback Logic

Google's preview models occasionally return 500/503 when under load. The server had fallback logic, and we replicated it:

```swift
func scan(image: UIImage, mode: ScanMode, prompt: String) async throws -> NutritionEntry {
    let config = mode == .label ? GeminiModelConfig.labelScan : GeminiModelConfig.foodPhotoScan
    
    do {
        return try await callGeminiAPI(config: config, /* ... */)
    } catch let error as ScanError where shouldFallback(error) {
        // Primary model failed — try the stable fallback
        let fallbackConfig = GeminiModelConfig(
            model: config.fallbackModel,
            thinkingLevel: config.thinkingLevel,
            fallbackModel: config.fallbackModel
        )
        return try await callGeminiAPI(config: fallbackConfig, /* ... */)
    }
}
```

### 5. Onboarding API Key Page

New users need to set up their API key before they can scan anything. We added a 5th page to the onboarding flow (inserted as page 1, right after Welcome):

```
Welcome → API Key → Goals → Camera → HealthKit
```

The API key page has three states:
1. **Initial**: Shows a link to Google AI Studio to get a free key, plus a SecureField for pasting it
2. **Key entered**: Shows a "Save" button next to the field
3. **Key saved**: Shows a green checkmark confirmation

This is optional during onboarding — the "Next" button is always available. Users who skip it will be prompted when they first try to scan (via `ScanError.noAPIKey`).

### 6. Settings API Key Management

For users who need to change or delete their key after onboarding, SettingsView got a new section:

- Status indicator (✓ Key saved / No key set)
- Change Key / Set API Key toggle button  
- SecureField for input with Save/Cancel buttons
- Delete Key button (destructive, with confirmation via `.role(.destructive)`)
- Help text linking to Google AI Studio

---

## What Went Right

1. **The Gemini REST API is genuinely simple.** One endpoint, JSON in/out, API key as query parameter. No OAuth, no tokens, no refresh flow. The entire API client is ~100 lines of Swift.

2. **Codable structs mapped perfectly.** The Gemini request/response shapes translated directly to Swift structs with no custom decoding needed. `responseMimeType: "application/json"` forces Gemini to return parseable JSON, avoiding any regex/markdown-stripping hacks.

3. **Build remained clean throughout.** Every intermediate step compiled. No cascading type errors, no missing imports. The project's zero-dependency approach meant no linking issues.

4. **Server prompts transferred verbatim.** The `LABEL_PROMPT` and `FOOD_PHOTO_PROMPT` from `server/index.js` were copied directly into Swift static strings. These prompts are battle-tested — they specify canonical nutrient IDs, output format, and edge cases. No prompt engineering needed on the iOS side.

## What Went Wrong

1. **Almost forgot the thinking parts.** Initial implementation grabbed `parts.first?.text` which returns the chain-of-thought reasoning, not the actual nutrition JSON. This would have caused a JSON parse failure on every food photo scan (which uses `HIGH` thinking). Caught during code review, not at runtime.

2. **Base64 encoding increases payload size by ~33%.** The server used multipart form-data which sends binary directly. Base64 encoding a 2MB JPEG creates a ~2.7MB JSON string. For the Gemini API this is fine (they accept multi-MB requests), but it's worth knowing. The image resizing to max 2000px and 0.9 quality JPEG compression mitigates this — typical payload is 200-400KB base64.

## Security Considerations

- **API key in URL query parameter**: Yes, this means the key appears in the URL. Google's Gemini API requires this. HTTPS encrypts the full URL in transit. The key is never logged, never stored in UserDefaults, never included in crash reports. Keychain storage is the most secure option iOS provides short of Secure Enclave (which doesn't support arbitrary data).

- **No rate limiting**: The server proxy could enforce rate limits. With BYOK, the user's own Google quota applies. Google's free tier is generous (15 RPM for Pro, 30 RPM for Flash), and the user can see their own usage in Google AI Studio.

- **Key rotation**: If a user suspects their key is compromised, they can delete it in Settings and generate a new one in Google AI Studio. The app stores exactly one key at a time.

---

## Architecture Comparison

| Aspect | Before (Render Proxy) | After (BYOK) |
|--------|----------------------|---------------|
| Latency | Phone → Render → Google → Render → Phone | Phone → Google → Phone |
| Cold start | 30-60s (Render free tier) | None |
| Monthly cost | $0 (free tier) to $7+ (paid) | $0 forever |
| Dependencies | Express.js, @google/generative-ai SDK | None (URLSession) |
| API key location | Render env var | iOS Keychain |
| User setup | None | Paste API key once |
| Failure modes | Render down, Google down | Google down |

The tradeoff is user friction: they need to get and paste an API key. For a developer-audience open source app, this is acceptable. For a mass-market app, you'd want a server proxy (or Apple's on-device models when they eventually ship).

---

## Files Changed

| File | Change |
|------|--------|
| `OpenFoodJournal/Services/KeychainService.swift` | **New** — Keychain CRUD for API keys |
| `OpenFoodJournal/Services/ScanService.swift` | **Rewritten** — Direct Gemini REST, removed multipart/Render code |
| `OpenFoodJournal/Views/Settings/SettingsView.swift` | **Modified** — Added API key management section |
| `OpenFoodJournal/Views/Onboarding/OnboardingView.swift` | **Modified** — Added API key page (page 1 of 5) |
| `.claude/skills/openfoodjournal/SKILL.md` | **Updated** — Reflects BYOK architecture |

**692 insertions, 133 deletions** across 5 files. Net increase is mostly the Gemini request/response Codable structs and the prompt strings (which were previously only on the server).

---

## Lessons for Your Own Projects

1. **Question every proxy server.** If your server is just forwarding requests to a third-party API, the client can probably call that API directly. Proxies make sense for auth (hiding keys from browsers), rate limiting, or response transformation. For a native app with Keychain storage, the auth argument evaporates.

2. **`responseMimeType: "application/json"` is magic.** Without it, Gemini wraps JSON in markdown code blocks (`\`\`\`json ... \`\`\``), and you need regex to extract it. With it, you get clean parseable JSON every time. One line saves an entire class of parsing bugs.

3. **Always read the last part, not the first.** Gemini's thinking models prepend chain-of-thought reasoning as additional response parts. The actual answer is always last. This applies to any model with `thinkingLevel` > NONE.

4. **Keychain > UserDefaults for secrets.** The API is uglier (C-style `SecItem*` functions with `CFDictionary`), but it's the right tool. Wrap it in a small helper struct and never think about it again. The delete-then-add pattern for upserts is simpler than `SecItemUpdate`.

5. **Copy battle-tested prompts verbatim.** We had months of prompt iteration on the server side. Rather than rewriting for iOS, we copied the exact strings. Prompt engineering is expensive — don't redo it when porting platforms.
