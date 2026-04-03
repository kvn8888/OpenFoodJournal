# OpenFoodJournal

A privacy-first iOS food journal with AI-powered nutrition scanning. Point your camera at a nutrition label or a plate of food and get instant macro/micronutrient tracking — no manual data entry required.

Built with SwiftUI, SwiftData, and Liquid Glass for iOS 26+.

---

## Features

### AI-Powered Scanning
- **Nutrition label scan** — Snap a photo of any nutrition label. Gemini 3.1 Flash Lite extracts all macros and micronutrients in under 2 seconds.
- **Food photo recognition** — Take a picture of your meal. Gemini 3.1 Pro with high reasoning estimates calories, protein, carbs, fat, and common micros.
- **Review before logging** — Every scan result is editable before committing to your journal.

### Daily Journal
- **Weekly calendar strip** — Horizontally scrollable with momentum snapping, progress rings per day, 52 weeks of history.
- **Macro summary bar** — At-a-glance calorie count + protein/carbs/fat progress rings + two configurable micronutrient ring slots (long-press to edit).
- **Meal sections** — Breakfast, lunch, dinner, snack. Swipe to edit or delete entries. Tap to view full nutrition detail.
- **Radial action menu** — Bottom-center FAB fans out into Scan / Manual Entry / Containers / Food Bank shortcuts.

### Food Bank
- **Save foods for reuse** — Any scanned or manually entered food can be saved to your personal library.
- **Search, sort, log** — Find saved foods by name, sort by last used or alphabetical, swipe right to log directly.
- **Serving mappings** — Define per-food unit conversions (e.g., "1 cup = 244g") for accurate re-logging in different portions.

### Container Tracking
- **Weight-based tracking** — For bulk items like protein tubs or cereal boxes. Enter start weight, weigh when done, and the app derives exact consumption.
- **Recently used** — Quick access to the last 3 foods you've tracked in containers.

### Micronutrient Tracking
- **30 FDA-recognized nutrients** — Vitamins A through K, minerals, fiber, cholesterol, and more, each with daily value targets.
- **Configurable summary rings** — Choose which two micronutrients appear on your daily dashboard.
- **Full breakdown view** — Expandable progress bars for every tracked micronutrient.

### History & Charts
- **Calendar grid** — Month view with color-coded progress indicators per day.
- **Macro bar charts** — Weekly/monthly trends for each macro, with over-goal visual indicators.
- **Nutrition detail** — Tap any day to see full macro and micro breakdowns.

### Health & Sync
- **Apple HealthKit** — Opt-in writes for calories, protein, carbs, fat, and 10+ micronutrients. Reads active energy burned for net calorie display.
- **iCloud sync** — Local-first SwiftData with automatic CloudKit sync across all your Apple devices.
- **CSV export** — Export your entire food journal as a CSV file from Settings.

### Sources & Disclaimers
- **FDA citations** — Daily Value percentages linked to 21 CFR §101.9 and FDA guidelines.
- **AI accuracy notes** — Inline disclaimers on scan results noting estimates may differ from actual values.
- **Health disclaimer** — Clear "Not Medical Advice" notice with links to all data sources.

---

## Architecture

```
┌─────────────────────────────────────────────┐
│  iOS App (SwiftUI + SwiftData)              │
│                                             │
│  OpenFoodJournalApp                         │
│    ├─ NutritionStore (CRUD + queries)       │
│    ├─ ScanService (camera → Gemini REST)    │
│    ├─ HealthKitService (Apple Health)       │
│    ├─ KeychainService (API key storage)     │
│    └─ UserGoals (@Observable + @AppStorage) │
│                                             │
│  ContentView (4-tab TabView)                │
│    ├─ Journal  → DailyLogView               │
│    ├─ Food Bank → FoodBankView              │
│    ├─ History  → HistoryView                │
│    └─ Settings → SettingsView               │
└──────────────┬──────────────────────────────┘
               │
    ┌──────────┴──────────┐
    │ HTTPS (BYOK)        │ CloudKit (automatic)
    ▼                     ▼
┌────────────┐  ┌─────────────────┐
│ Gemini API │  │ iCloud Private  │
│ (Google)   │  │ Database        │
└────────────┘  └─────────────────┘
```

**Local-first**: SwiftData writes happen immediately for instant UI. CloudKit sync is automatic — the private database keeps all devices in sync transparently.

**BYOK (Bring Your Own Key)**: Users provide their own Gemini API key (free from aistudio.google.com). The key is stored in the iOS Keychain and API calls go directly from the device — no proxy server involved.

**Service injection**: All services are created at app launch and passed through SwiftUI's `@Environment`. No singletons.

---

## Data Models

| Model | Purpose |
|-------|---------|
| `DailyLog` | One per day, keyed by midnight-normalized date. Owns entries via cascade delete. |
| `NutritionEntry` | Single food log — macros, micros, brand, serving info, optional source image. |
| `SavedFood` | Reusable food template in the Food Bank. Same nutrition fields as an entry. |
| `TrackedContainer` | Weight-based container. Snapshots food nutrition at creation, derives consumption from weight delta. |
| `UserGoals` | Daily calorie/protein/carbs/fat targets. Persisted via `@AppStorage`. |

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| UI | SwiftUI + Liquid Glass (iOS 26) |
| Local Data | SwiftData (`@Model`) |
| State | `@Observable` + `@Environment` |
| AI | Google Gemini 3.1 (Flash Lite for labels, Pro for food photos) — BYOK |
| Sync | CloudKit (iCloud Private Database) |
| Security | iOS Keychain (API key storage) |
| Health | Apple HealthKit |

---

## Getting Started

### Prerequisites

- **Xcode 26+** (macOS)
- A **Google Gemini API key** (optional, for scan functionality — get one free at [aistudio.google.com](https://aistudio.google.com/apikey))

### Build & Run

```bash
# Clone the repo
git clone https://github.com/kvn8888/OpenFoodJournal.git
cd OpenFoodJournal

# Build from terminal
xcodebuild -project OpenFoodJournal.xcodeproj \
  -scheme OpenFoodJournal \
  -destination generic/platform=iOS \
  build
```

Or open `OpenFoodJournal.xcodeproj` in Xcode and run on a simulator or device.

> **Note:** The `server/` directory contains a legacy Express.js proxy from an earlier architecture. It is **not used** by the app. The current app communicates directly with the Gemini API and uses CloudKit for data sync — no server is required to build, run, or use OpenFoodJournal.

---

## Project Structure

```
OpenFoodJournal/
├── Models/           # SwiftData models + enums + mock data
├── Services/         # NutritionStore, ScanService, HealthKitService, KeychainService
├── Views/
│   ├── DailyLog/     # Journal tab — calendar strip, macro bar, meal sections
│   ├── FoodBank/     # Saved foods — search, sort, edit, log
│   ├── Container/    # Weight-based container tracking
│   ├── History/      # Calendar grid + macro charts
│   ├── ManualEntry/  # Manual food logging + entry editing
│   ├── Scan/         # Camera capture + scan result review
│   ├── Settings/     # Goals editor, app settings, sources & disclaimers
│   ├── Onboarding/   # 6-page onboarding with API key setup
│   └── Shared/       # Reusable components (MacroRingView, RadialMenuButton, etc.)
├── Assets.xcassets/  # App icon + accent color
└── ContentView.swift # Root 4-tab navigation
```

---

## License

This project is licensed under the [AGPL-3.0](LICENSE).
