# Preparing an iOS App for the App Store: A Complete Checklist Session

This retrospective covers the full process of taking a working iOS food journal app from "developer tool" to "App Store ready" in one continuous session. We migrated the sync backend from Turso to CloudKit, ran an automated audit, fixed every blocker, and built an onboarding flow. Here's everything we did, what we learned, and what would trip up someone doing this for the first time.

---

## Starting Point

The app — OpenFoodJournal — was a fully functional food journaling tool built with SwiftUI, SwiftData, and Liquid Glass (iOS 26). It had:
- AI-powered nutrition scanning (Gemini via a proxy server)
- Manual food entry with a "Food Bank" for reusable templates
- Container tracking (weight-based portion math)
- History with charts and calendar view
- HealthKit integration

But it synced data through a custom Turso (libSQL) backend with an Express REST API — 15+ endpoints, a 200-line `SyncService.swift`, and fire-and-forget `Task` blocks in nearly every view. Not ideal for App Store distribution where you want minimal server dependency.

---

## Part 1: CloudKit Migration

### The One-Line Fix That Replaces 1,000 Lines

The entire Turso sync layer (SyncService.swift + API models + 15 Task blocks across views + server CRUD routes) was replaced by a single argument:

```swift
let config = ModelConfiguration(
    cloudKitDatabase: .private("iCloud.k3vnc.OpenFoodJournal")
)
```

That's it. SwiftData + CloudKit handles all sync automatically. No push/pull logic, no conflict resolution, no server endpoints for data operations.

### CloudKit's Model Requirements (The Hard Part)

CloudKit imposes rules that local-only SwiftData doesn't care about. These are the three that bit us:

**1. All stored properties need defaults:**
```swift
// ❌ Local-only SwiftData is fine with this
var name: String

// ✅ CloudKit needs this (record may materialize before all fields sync)
var name: String = ""
```

**2. No `@Attribute(.unique)`:**
```swift
// ❌ CloudKit can't enforce uniqueness across devices
@Attribute(.unique) var date: Date

// ✅ App-level dedup instead
var date: Date = Date()
// In NutritionStore: fetchOrCreateLog(for:) handles dedup
```

**3. Relationships must be optional:**
```swift
// ❌ Non-optional array — CloudKit can't guarantee the related records exist yet
var entries: [NutritionEntry] = []

// ✅ Optional with computed accessor for convenience
var entries: [NutritionEntry]? = []
var safeEntries: [NutritionEntry] { entries ?? [] }
```

The `safeEntries` pattern is worth highlighting. Making relationships optional cascades through your entire codebase — every `log.entries.count`, `.reduce`, `.filter` breaks. The computed property lets you do a single bulk replacement (`log.entries.` → `log.safeEntries.` for reads) while writes use `log.entries?.append(entry)`.

### The Enum Default Gotcha

This is the kind of bug that wastes 30 minutes if you don't know about it:

```swift
// ❌ Compiles in normal Swift, fails in @Model macro expansion
var mealType: MealType = .snack

// ✅ Must be fully qualified in @Model classes
var mealType: MealType = MealType.snack
```

The `@Model` macro expands your class at compile time, and during that expansion, the Swift compiler can't resolve shorthand enum references. The error message just says "macro expansion failed" with no hint about which default value is the problem. **If you see unexplained `@Model` macro errors, check your enum defaults.**

### Removing Sync Code: Surgery Across 15 Files

The fire-and-forget pattern was everywhere:

```swift
// This pattern appeared in ~15 different view files
if let sync = nutritionStore.syncService {
    Task { try? await sync.createEntry(entry) }
}
```

Each file needed surgical removal of:
- `@Environment(SyncService.self)` declarations
- `Task { try? await sync.someMethod() }` blocks (1-3 per file)
- Renamed method calls (`saveAndSyncEntry` → `saveEntry`)

The lesson: **fire-and-forget sync calls spread like mold.** What starts as a "simple" pattern in one view ends up coupling your entire UI layer to a sync service. If you're designing a sync architecture, either:
- Use CloudKit from the start (zero sync code in views), or
- Centralize sync in a single observer/middleware, not scattered Task blocks

### The Data Migration Tool

Users with existing Turso data need a way to import it. We built a one-time migration view in Settings that:

```swift
// 1. Fetches all data from the old Turso endpoint
let url = URL(string: "\(serverURL)/api/sync")!
let (data, _) = try await URLSession.shared.data(from: url)
let syncData = try JSONDecoder().decode(TursoSyncResponse.self, from: data)

// 2. Inserts into local SwiftData (CloudKit picks up automatically)
for tursoLog in syncData.dailyLogs {
    let log = DailyLog(date: parseDate(tursoLog.date)!)
    modelContext.insert(log)
}
// ... same for entries, foods, containers

// 3. De-duplicates by UUID (skip if already local)
let existingIDs = Set(existingEntries.map { $0.id })
guard !existingIDs.contains(entryID) else { continue }
```

The API response types are defined as `private` structs inside the migration file — they're one-time use, no reason to pollute the model layer.

---

## Part 2: The App Store Audit

After the migration compiled clean, we ran a comprehensive audit. Here's the checklist (useful for any iOS app):

### ✅ What Was Already Done
| Item | Status |
|------|--------|
| `NSCameraUsageDescription` | Present in Info.plist |
| `NSHealthShareUsageDescription` | Present |
| `NSHealthUpdateUsageDescription` | Present |
| App Icon (light mode) | Configured in Assets.xcassets |
| Launch Screen | Auto-generated via `UILaunchScreen_Generation` |
| App Transport Security | All HTTPS, no exceptions needed |
| Version/Build numbers | 1.0/1 — fine for initial release |
| Minimum Functionality (4.2) | Easily passes with AI scanning + journaling + charts |

### ❌ Blockers We Found and Fixed

**1. Missing HealthKit Entitlement**

The app used HealthKit (wrote nutrition data to Apple Health) but the entitlements file only had iCloud and Push Notifications. HealthKit authorization would silently fail without this:

```xml
<!-- Added to OpenFoodJournal.entitlements -->
<key>com.apple.developer.healthkit</key>
<true/>
<key>com.apple.developer.healthkit.access</key>
<array/>
```

**Lesson:** Having `NSHealthUpdateUsageDescription` in Info.plist is necessary but not sufficient. You also need the HealthKit capability entitlement.

**2. No Privacy Policy**

Apple requires a privacy policy for any app that collects data. Our app sends camera images to an external server and writes to HealthKit — both require disclosure.

We created:
- `PRIVACY.md` — A hosted privacy policy covering all data: food logs (iCloud), camera images (Gemini proxy), HealthKit (local only), no tracking
- `PrivacyInfo.xcprivacy` — Apple's privacy manifest declaring collected data types and Required Reason API usage

The privacy manifest (`PrivacyInfo.xcprivacy`) is required since iOS 17 and declares:
```xml
<!-- What we collect -->
<key>NSPrivacyCollectedDataTypes</key>
<array>
    <!-- Health data: HealthKit writes -->
    <dict>
        <key>NSPrivacyCollectedDataType</key>
        <string>NSPrivacyCollectedDataTypeHealth</string>
        <!-- Not linked to identity, not used for tracking -->
    </dict>
    <!-- Photos: camera images for AI scanning -->
    <dict>
        <key>NSPrivacyCollectedDataType</key>
        <string>NSPrivacyCollectedDataTypePhotosorVideos</string>
    </dict>
</array>

<!-- Required Reason APIs -->
<key>NSPrivacyAccessedAPITypes</key>
<array>
    <!-- UserDefaults (for @AppStorage) -->
    <dict>
        <key>NSPrivacyAccessedAPIType</key>
        <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
        <key>NSPrivacyAccessedAPITypeReasons</key>
        <array>
            <string>CA92.1</string> <!-- App-specific data -->
        </array>
    </dict>
</array>
```

**3. AGPL-3.0 vs App Store (Legal)**

The AGPL and App Store have a well-documented conflict:
- AGPL requires users be able to modify and redistribute the software
- App Store applies FairPlay DRM and restricts redistribution
- The FSF has stated these are incompatible (VLC was removed from the App Store over this)

**Solution for sole copyright holders:** Add an App Store Exception clause. This is a well-established pattern (Qt, VLC later did this). You keep AGPL for the public repo but explicitly permit App Store distribution:

> You may distribute copies of OpenFoodJournal through Apple's App Store, provided that the source code remains publicly available under the AGPL-3.0 license.

This only works if you own all the copyright. Third-party contributors would need to agree.

---

## Part 3: Onboarding Flow

New users were landing on an empty journal with no context. We built a 4-page swipeable onboarding:

### Page Architecture

```swift
struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var currentPage = 0
    
    var body: some View {
        TabView(selection: $currentPage) {
            welcomePage.tag(0)      // Features overview
            goalsPage.tag(1)        // Macro goal sliders
            cameraPage.tag(2)       // Camera permission
            healthKitPage.tag(3)    // HealthKit opt-in + finish
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
    }
}
```

**Key design decisions:**

1. **`@AppStorage` flag, not a model property** — Onboarding state doesn't need CloudKit sync. `@AppStorage("hasCompletedOnboarding")` is simpler and per-device (which is what you want — each device should onboard independently).

2. **Goals are set during onboarding, not after** — Users who skip goal-setting never come back. The sliders have sensible defaults (2000 kcal / 150g protein / 250g carbs / 65g fat) so users can just swipe through and adjust later.

3. **Camera permission is requested with context** — Instead of a cold system prompt, we show a page explaining *why* we need the camera before triggering `AVCaptureDevice.requestAccess(for: .video)`. This dramatically improves grant rates.

4. **HealthKit is optional with a toggle** — Not a system prompt. The user toggles it on, and we request authorization only if they opt in. This avoids the jarring HealthKit permission dialog for users who don't want it.

### Wiring Into the App

```swift
// In MacrosApp body:
if hasCompletedOnboarding {
    ContentView()
        // ... environments
} else {
    OnboardingView()
        // ... environments
}
```

The `@AppStorage` binding means the transition from onboarding to the main app happens automatically with animation when `hasCompletedOnboarding` flips to `true`.

### Color.accentColor, Not .accent

Quick build fix: `.accent` isn't a valid `ShapeStyle` member. Use `Color.accentColor` for foreground styles and tints. This comes up in any file-from-scratch where you might type `.accent` out of habit.

---

## What We'd Do Differently

1. **Start with CloudKit if you know the app is going to the App Store.** Retrofitting CloudKit requirements onto existing models costs as much as building them right the first time.

2. **Create `PrivacyInfo.xcprivacy` early.** It's easy to forget, and App Store Review will reject you for it since iOS 17.

3. **Test with a real provisioning profile before the final push.** We verified the code compiles with `CODE_SIGNING_ALLOWED=NO`, but the profile still needs iCloud + Push Notifications capabilities from the Developer portal. That's a manual step that can't be automated.

4. **Keep sync code centralized, not scattered across views.** The fire-and-forget pattern was convenient to add but expensive to remove. A middleware/observer approach would have made the migration trivial.

---

## Final Commit Log

| Commit | Description | Delta |
|--------|-------------|-------|
| `01516c2` | CloudKit migration + Turso removal | +670 / −1,018 |
| `7b7eea2` | Retrospective + project skill update | +377 / −52 |
| `90227dc` | HealthKit entitlement, privacy policy, AGPL exception | +185 |
| `e6764fc` | Onboarding flow | +329 / −12 |

Total: **~1,500 lines added, ~1,100 removed** across 4 commits. Net code is simpler — the sync layer is gone, replaced by one ModelConfiguration argument.

---

## Remaining Steps for Submission

1. **Provisioning profile** — Enable iCloud + Push Notifications capabilities in Apple Developer portal, regenerate profile
2. **App Store Connect** — Create app listing, upload screenshots, enter privacy policy URL, set up pricing
3. **Archive build** — `aps-environment` auto-switches to `production` on Archive (verify this)
4. **TestFlight** — Internal testing before public submission
5. **Hide "Import from Turso"** — Either remove from Settings for public release or gate behind a developer flag
6. **Consider increasing scan timeout** — Render free tier has 30-50s cold starts; the 30s request timeout may not be enough
