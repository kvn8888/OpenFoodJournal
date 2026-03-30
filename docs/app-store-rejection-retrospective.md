# From Rejection to Resolution: Fixing Apple's Guideline 1.4.1 for a Nutrition App

I submitted my first iOS app to the App Store and it got rejected. The rejection email from Apple was polite but firm: **Guideline 1.4.1 — Safety — Physical Harm.** The app included "medical information" without citations. Here's how I diagnosed the issue, what I got wrong in my initial audit, and how I fixed it in a single commit.

## The Starting Point

OpenFoodJournal is a SwiftUI food journaling app that uses Google's Gemini AI to scan nutrition labels and estimate nutrition from food photos. It tracks 30+ micronutrients against FDA Daily Values, writes to Apple Health, and lets users set calorie/macro goals. Everything worked. The build passed. TestFlight was smooth.

Then Apple rejected it.

## Step 1: Diagnosing Before Knowing

Before looking at the actual rejection reason, I ran a comprehensive audit using an App Store Review skill — a structured checklist covering all five guideline sections (Safety, Performance, Business, Design, Legal). The goal was to see if I could identify the issue from code alone.

**What the audit found (ranked by likelihood):**

| Risk | Issue | Guideline |
|------|-------|-----------|
| CRITICAL | Reviewer API key placeholder not filled in | 2.1 |
| CRITICAL | Reviewer notes falsely claimed "HealthKit data is never read" | 2.3 |
| CRITICAL | README described wrong architecture (Turso/Express vs CloudKit) | 2.3 |
| HIGH | BYOK requires leaving app for external API key | 4.2 |
| HIGH | No health/medical disclaimer for AI estimates | 1.4.1 |

I ranked the "no health disclaimer" as #5. The actual rejection reason? **Exactly that — #5, Guideline 1.4.1.**

The lesson: I correctly identified the issue during audit but underestimated its severity. Apple is extremely strict about health/nutrition apps because inaccurate nutrition data can genuinely harm users with medical conditions.

## Step 2: Mapping Every Citation Needed

Before writing any fix code, I mapped every place in the app that shows health or nutrition information:

**FDA Daily Values (30 micronutrients)**
The app has a `KnownMicronutrients.swift` file with all 30 FDA Daily Values hardcoded (Vitamin A = 900 mcg, Calcium = 1300 mg, etc.). The code had a comment citing `21 CFR 101.9` — but comments don't count. Users never see code comments. The citation needed to be in the UI.

```swift
// This comment in KnownMicronutrients.swift was invisible to users:
// Daily values are based on the FDA 2020 Daily Value Reference (2000 cal diet).
// Sources: 21 CFR 101.9
```

The `NutritionDetailView` showed progress bars like "45 / 2300 mg (2%)" against these daily values — but never said *where* the 2300 mg reference came from.

**AI-Estimated Nutrition**
When you scan a food photo, the app shows "Estimated (~72% confidence)" in orange text. That's good labeling — but it didn't say the estimation might be wrong or shouldn't be used for medical decisions.

**Macro Calorie Formula**
The Goals Editor shows "Protein & carbs = 4 kcal/g · Fat = 9 kcal/g" — the Atwater general factor system. This is nutritional science information presented without a source.

**Default Goals**
The app defaults to 2000 kcal, 150g protein, 200g carbs, 65g fat. These are presented as editable starting points, but showing specific numbers implies a recommendation.

## Step 3: The Fix — Centralized + Inline Citations

Most approved health apps on the App Store use a two-layer approach:

1. **A centralized disclaimer page** accessible from Settings — easy for reviewers to find
2. **Brief inline citations** where health data is displayed — easy for users to see

### The Centralized View

I created `HealthDisclaimerView.swift` with five sections:

```swift
struct HealthDisclaimerView: View {
    var body: some View {
        List {
            // General "not medical advice" disclaimer
            Section {
                Label("Not Medical Advice", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("OpenFoodJournal is a food journaling tool... not intended to 
                     diagnose, treat, cure, or prevent any disease...")
            }

            // FDA Daily Values — the primary citation Apple wanted
            Section {
                Link(destination: URL(string: "https://www.fda.gov/food/...")!) {
                    Label("FDA: Daily Value on Nutrition Labels", systemImage: "link")
                }
                Link(destination: URL(string: "https://www.ecfr.gov/current/title-21/...")!) {
                    Label("21 CFR §101.9 — Nutrition Labeling", systemImage: "link")
                }
            } header: { Text("Nutrition References") }

            // Atwater system (4/4/9 formula)
            // AI estimation accuracy
            // Apple Health data handling
        }
        .navigationTitle("Sources & Disclaimers")
    }
}
```

The key design decisions:
- **Clickable links** to FDA.gov and eCFR.gov — Apple's rejection specifically asked for "links to sources"
- **Structured by topic** — each section covers one type of health information
- **NavigationLink from Settings** — one tap to reach, exactly where a reviewer would look

### Inline Citations

Three views got brief footnotes:

**NutritionDetailView** — Added a footer below all micronutrient sections:
```swift
Section {
    HStack(spacing: 6) {
        Image(systemName: "info.circle")
        Text("Daily values based on a 2,000-calorie diet, per ")
        + Text("[FDA guidelines](https://www.fda.gov/food/...)")
        + Text(". AI-estimated values are approximations.")
    }
    .font(.caption2)
}
```

**ScanResultCard** — Added under the "Estimated (~X% confidence)" label:
```swift
Text("AI estimates may differ from actual values. Verify before 
     relying on this data for dietary decisions.")
    .font(.caption2)
    .foregroundStyle(.secondary)
```

**GoalsEditorView** — Updated the existing footer:
```swift
// Before:
Text("Protein & carbs = 4 kcal/g · Fat = 9 kcal/g. Use this as a sanity check.")

// After:
Text("Protein & carbs = 4 kcal/g · Fat = 9 kcal/g (Atwater system). ...Consult a 
     healthcare professional for personalized guidance.")
```

## The Gotcha: False Information in Reviewer Notes

While fixing 1.4.1, I discovered something worse in the reviewer notes. The `app-store-metadata.md` doc — which I copy-paste into App Store Connect's "Notes for Review" — contained this:

> "HealthKit data is never read, shared, or sent to any server."

But the app **does** read HealthKit data. `HealthKitService.swift` reads `activeEnergyBurned` to display daily calorie balance. The notes also only mentioned writing "calories, protein, carbs, fat" when the app actually writes 10+ nutrient types including fiber, sodium, cholesterol, and vitamins.

This is a Guideline 2.3 violation (Accurate Metadata) and could have been a separate rejection on its own. I corrected the reviewer notes to accurately describe all HealthKit read/write operations:

```markdown
# Before (false):
HealthKit data is never read, shared, or sent to any server.

# After (accurate):
The app writes to Apple HealthKit (calories, protein, carbs, fat, fiber, sugar, 
sodium, cholesterol, saturated fat, and select vitamins/minerals) only when enabled. 
The app also reads active energy burned data to display daily calorie balance. 
HealthKit data is never sent to any external server.
```

## What I Got Right and Wrong

**Right:**
- The app-store-review skill correctly identified all five risk areas
- The actual rejection reason was in the audit results
- The fix was straightforward once I mapped all citation points

**Wrong:**
- I ranked 1.4.1 as #5 (HIGH) when it should have been #1 (CRITICAL). For any health/nutrition app, health citations are the most common rejection reason. I should have known this.
- I had code comments citing FDA sources but assumed that was sufficient. Apple wants **user-visible** citations with **clickable links**.
- The false HealthKit claim in reviewer notes was written during a compliance sprint and never double-checked against the actual code. Reviewer notes are assertions to Apple — they need the same rigor as the code itself.

## What's Next

The fix is committed and pushed. Before resubmitting:
1. Replace the API key placeholder in reviewer notes with an actual test key
2. Consider updating `README.md` for the `app-store` branch (currently describes main's Turso architecture)
3. Generate a new build in Xcode and upload via App Store Connect
4. Monitor the review for any follow-up on the other audit findings (BYOK model, AGPL license, README mismatch)

The broader takeaway: **code comments are for developers, UI text is for users, and reviewer notes are sworn testimony.** All three need to be accurate, but only the last two matter for App Store approval.

---

*Your code can be perfect and your app can still get rejected. The App Store review process tests your documentation as much as your software.*
