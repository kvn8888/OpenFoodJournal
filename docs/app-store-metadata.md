# App Store Metadata — OpenFoodJournal

Use this file when filling out App Store Connect fields.

---

## App Name (30 chars max)

```
OpenFoodJournal
```

(15 chars — leaves room if you want to add a descriptor like "OpenFoodJournal: AI Tracker")

---

## Subtitle (30 chars max)

```
AI Nutrition Label Scanner
```

(26 chars — covers "AI", "nutrition", "label", "scanner" — all high-intent search terms)

**Alternatives to consider:**
- `Scan Labels, Track Macros` (26 chars)
- `AI Food & Macro Tracker` (23 chars)
- `Scan Food, Track Nutrition` (26 chars)

---

## Keywords (100 chars max, comma-separated, no spaces after commas)

```
calorie,macro,protein,carbs,fat,diet,food,journal,scanner,health,meal,log,icloud,micronutrient,BYOK
```

(99 chars)

**Strategy:**
- Don't repeat words already in the title ("OpenFoodJournal") or subtitle ("AI", "nutrition", "label", "scanner") — Apple auto-combines them
- "calorie" and "macro" are the highest-traffic terms in this category
- "BYOK" captures the privacy-conscious niche searching for bring-your-own-key apps
- "icloud" signals sync capability (differentiator vs. apps requiring accounts)
- Singular forms only — Apple indexes plurals automatically

---

## Description (4000 chars max)

```
OpenFoodJournal is a free, open-source nutrition tracker that uses AI to scan food labels and estimate nutrition from food photos — no account required, no subscriptions, no ads.

SCAN ANYTHING
Point your camera at a nutrition label and get macro and micronutrient data you can review before saving. Or photograph your meal from multiple angles and let AI estimate calories, protein, carbs, fat, and common micronutrients.

YOUR KEY, YOUR DATA
OpenFoodJournal uses a Bring Your Own Key (BYOK) approach. You provide your own Google Gemini API key — your food photos go directly from your device to Google's API. No middleman server, no account, no ads, no tracking.

TRACK YOUR MACROS
• Daily calorie, protein, carbs, and fat tracking with visual progress rings
• 30 micronutrients tracked automatically (fiber, sodium, vitamins, minerals, and more)
• Organize meals by breakfast, lunch, dinner, and snacks
• Weekly calendar strip for quick day-to-day navigation

FOOD BANK
Save foods you eat regularly and log them with one tap. Supports custom serving sizes, unit conversions (cups to grams, pieces to servings), brand organization, archive cleanup, and optional AI-generated food icons.

BUILD REUSABLE FOODS
Create composite foods from copied ingredient snapshots, so future edits do not change past journal entries. Build restaurant-style nutrition calculators for customizable meals and save those builds to your journal.

AI SEARCH
Search for nutrition data from the Food Bank. Gemini can use Google Search grounding to find data for packaged foods and restaurant items, then opens an editable review form before anything is saved.

CONTAINER TRACKING
Track foods by weight — enter a start weight when you open a container, then log the final weight when you're done. The app calculates exactly how much you consumed.

SYNC ACROSS DEVICES
Your data syncs automatically via iCloud — no account creation, no email, no password. Just sign in to iCloud on your devices and everything stays in sync.

APPLE HEALTH
Optionally write nutrition data to Apple Health. OpenFoodJournal uses deterministic HealthKit identifiers so edits replace OpenFoodJournal-owned samples instead of duplicating them, and includes repair tools for older synced entries.

HISTORY & CHARTS
Review your nutrition history with interactive charts. See trends in your calorie and macro intake over time.

EXPORT AND BACK UP
Export spreadsheet CSVs for analysis, save full JSON backups for restore-grade imports, and export recent AI diagnostics when troubleshooting scans or Assistant behavior.

PRIVACY FIRST
• No accounts or sign-ups
• No analytics or tracking
• No ads
• No server — your data lives on your device and in your personal iCloud
• Open source — verify everything at github.com/kvn8888/OpenFoodJournal

GETTING STARTED
1. Get a Gemini API key at aistudio.google.com
2. Paste it into the app during onboarding
3. Start scanning and tracking

OpenFoodJournal is licensed under AGPL-3.0. Built with SwiftUI, SwiftData, and CloudKit.
```

(Well within the 4,000-character limit. Deliberately concise — App Store descriptions that are too long get skimmed.)

---

## Primary Category

```
Health & Fitness
```

## Secondary Category

```
Food & Drink
```

---

## App Review Notes

Paste this into the "App Review Information → Notes" field:

```
This app requires a Google Gemini API key for the food scanning feature. The key can be created in Google AI Studio:

1. Go to https://aistudio.google.com/apikey
2. Click "Create API Key"
3. Copy the key
4. Paste it on the second onboarding page (or in Settings > Gemini API Key)

For your convenience, here is a test API key you can use for review:
[PASTE A DEDICATED REVIEW KEY IN APP STORE CONNECT BEFORE SUBMISSION]

The app works fully offline for manual food entry, Food Bank browsing, container tracking, history, CSV export, and JSON backup/export. The API key is only needed for AI-powered label/photo scanning, nutrition-calculator OCR import, optional generated Food Bank icons, and the Assistant.

New in version 1.3:
- Food Bank adds Composite Food, Nutrition Calculator, Open Food Facts search, Archive, brand organization, and optional generated icons.
- Label and food-photo scanning can use multiple photos and show clearer Gemini progress while the scan is running.
- Apple Health sync writes more nutrients, replaces OpenFoodJournal-owned samples idempotently, and includes repair actions for older OpenFoodJournal Health samples.
- Data tools now include restore-grade JSON backup/import, CSV export, Gemini diagnostic export, and a local Gemini usage/cost total.
- Meal type defaults are based on local device time and can be configured in Settings.

The app writes to Apple HealthKit (calories, protein, carbs, fat, fiber, sugar, sodium, cholesterol, saturated fat, and supported vitamins/minerals) only when the user explicitly enables the toggle in Settings > Integrations. The app also reads active energy burned data from HealthKit to display daily calorie balance. HealthKit data is never sent to any external server.

The app provides nutrition citations and a full health disclaimer under Settings > Sources & Disclaimers, referencing FDA Daily Values (21 CFR §101.9) and noting that AI-estimated nutrition values are approximations.
```

**Important:** Before submitting, create a dedicated Gemini API key for the reviewer and paste it into App Store Connect in place of the bracketed review-key line above. Do not commit that key to this repository. You can revoke it after approval.

---

## Promotional Text (170 chars max, editable anytime — no review needed)

```
New Food Bank tools, better scans, safer Apple Health sync, full backups, and AI diagnostics. Free, open-source, no account required.
```

(148 chars)

**Seasonal alternatives:**
- New Year: `Start 2026 right — scan your meals, track your macros, own your data. Free AI-powered nutrition tracking with no subscriptions or accounts.`
- Feature launch: `NEW: Composite foods, nutrition calculators, safer Apple Health sync, and full backups. Free, open-source, no account needed.`

---

## What's New (version 1.3)

```
Version 1.3 focuses on better logging workflows, safer Apple Health sync, and a more capable Food Bank.

• Food Bank now supports Composite Foods, Nutrition Calculators, Open Food Facts search, Archive, brand organization, and optional food icons.
• Scans support multiple photos and clearer Gemini progress while results are prepared.
• Apple Health sync now writes more nutrients, avoids duplicate OpenFoodJournal samples, and includes repair tools for older entries.
• Added configurable local meal times, full JSON backup/import, improved CSV export, Gemini diagnostic export, and a local Gemini usage/cost total.
```

---

## App Store Product Page Headlines

Apple allows up to 3 custom product pages (App Store Connect → App Store → Product Page Optimization). Each needs a headline and screenshot set.

### Default Product Page

**Headline:** `Scan Labels. Track Macros. Own Your Data.`

**Screenshot captions (in order):**
1. `Scan any label. Get instant macros.`
2. `Daily tracking at a glance.`
3. `Your Food Bank. Search, build, log.`
4. `Composite foods for repeat meals.`
5. `30+ nutrients and Apple Health sync.`
6. `Back up and restore your data.`

### Custom Product Page A — Privacy Focus

**Headline:** `No Account. No Ads. No Tracking. Just Nutrition.`

**Screenshot captions:**
1. `Your key. Your data. Your privacy.`
2. `Open source. Verify every line.`
3. `No account. Just iCloud.`
4. `AI scanning you control.`
5. `Every vitamin. Every mineral.`

### Custom Product Page B — AI Focus

**Headline:** `AI-Powered Nutrition in Seconds`

**Screenshot captions:**
1. `Scan multiple angles.`
2. `Search nutrition with Gemini.`
3. `Powered by your own API key.`
4. `Calories, protein, and 30+ nutrients.`
5. `Save, combine, and re-log foods.`

---

## Screenshot Strategy

Apple requires screenshots for each device size. Focus on iPhone 6.7" (iPhone 15 Pro Max) — smaller sizes auto-generate.

**Priority order for screenshots:**
1. **Scan in action** — camera pointed at a nutrition label with the ScanResultCard showing parsed macros
2. **Daily journal** — DailyLogView with macro rings filled, a few meal entries visible
3. **Food Bank** — list of saved foods with serving info
4. **Food Bank + menu** — Composite Food, Nutrition Calculator, Open Food Facts, Manual Entry, Archive, Manage Brands
5. **Nutrition detail** — NutrientBreakdownView showing all 30+ micronutrients
6. **History chart** — MacroChartView with a week of data

**Tips:**
- Use populated data (not empty states)
- Show the Liquid Glass UI — it's visually distinctive
- Dark mode screenshots can differentiate you in search results
- Captions should be benefit-focused, not feature-focused ("Track your progress" not "Macro ring chart")

---

## Privacy Policy URL

```
https://github.com/kvn8888/OpenFoodJournal/blob/app-store/PRIVACY.md
```

## Support URL

```
https://github.com/kvn8888/OpenFoodJournal/issues
```

## Marketing URL (optional)

```
https://github.com/kvn8888/OpenFoodJournal
```

---

## Screenshot Strategy (5-6 recommended)

| # | Screen | Callout Text |
|---|--------|-------------|
| 1 | Daily Log with macro rings filled | "Track macros at a glance" |
| 2 | Camera scanning a nutrition label | "Scan labels from multiple angles" |
| 3 | Food Bank + menu | "Search, combine, and build foods" |
| 4 | Composite Food or Nutrition Calculator | "Save repeat meals your way" |
| 5 | Settings showing Health/backup tools | "Sync, repair, and back up" |
| 6 | History view with charts | "See your trends over time" |

**Sizes needed:**
- 6.9" (1320 × 2868) — iPhone 16 Pro Max
- 6.7" (1290 × 2796) — iPhone 15 Pro Max / Plus (check "use for smaller sizes")

**Tools:** Rotato, AppMockUp (free), or custom Figma designs with device frames and gradient backgrounds.

---

## Age Rating

```
4+ (No objectionable content)
```

## Copyright

```
© 2026 Kevin C
```
