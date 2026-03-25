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
Point your camera at a nutrition label and get instant, accurate macro and micronutrient data. Or photograph your meal and let AI estimate calories, protein, carbs, fat, and 30+ micronutrients from the image alone.

YOUR KEY, YOUR DATA
OpenFoodJournal uses a Bring Your Own Key (BYOK) approach. You provide your own free Google Gemini API key — your food photos go directly from your device to Google's API. No middleman server, no data collection, no tracking.

TRACK YOUR MACROS
• Daily calorie, protein, carbs, and fat tracking with visual progress rings
• 30 micronutrients tracked automatically (fiber, sodium, vitamins, minerals, and more)
• Organize meals by breakfast, lunch, dinner, and snacks
• Weekly calendar strip for quick day-to-day navigation

FOOD BANK
Save foods you eat regularly and log them with one tap. Supports custom serving sizes, unit conversions (cups to grams, pieces to servings), and brand tracking.

CONTAINER TRACKING
Track foods by weight — enter a start weight when you open a container, then log the final weight when you're done. The app calculates exactly how much you consumed.

SYNC ACROSS DEVICES
Your data syncs automatically via iCloud — no account creation, no email, no password. Just sign in to iCloud on your devices and everything stays in sync.

APPLE HEALTH
Optionally write your daily nutrition data to Apple Health for a complete picture of your wellness.

HISTORY & CHARTS
Review your nutrition history with interactive charts. See trends in your calorie and macro intake over time.

PRIVACY FIRST
• No accounts or sign-ups
• No analytics or tracking
• No ads
• No server — your data lives on your device and in your personal iCloud
• Open source — verify everything at github.com/kvn8888/OpenFoodJournal

GETTING STARTED
1. Get a free Gemini API key at aistudio.google.com
2. Paste it into the app during onboarding
3. Start scanning and tracking

OpenFoodJournal is licensed under AGPL-3.0. Built with SwiftUI, SwiftData, and CloudKit.
```

(~1,800 chars — well within the 4,000 limit. Deliberately concise — App Store descriptions that are too long get skimmed.)

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
This app requires a Google Gemini API key for the food scanning feature. The key is free and takes 30 seconds to set up:

1. Go to https://aistudio.google.com/apikey
2. Click "Create API Key"
3. Copy the key
4. Paste it on the second onboarding page (or in Settings > Gemini API Key)

For your convenience, here is a test API key you can use for review:
[PASTE YOUR REVIEW KEY HERE BEFORE SUBMISSION]

The app works fully offline for manual food entry and browsing — the API key is only needed for AI-powered label/photo scanning.

The app writes to Apple HealthKit (calories, protein, carbs, fat) only when the user explicitly enables the toggle in Settings > Integrations. HealthKit data is never read, shared, or sent to any server.
```

**Important:** Before submitting, create a dedicated Gemini API key for the reviewer and paste it in place of `[PASTE YOUR REVIEW KEY HERE BEFORE SUBMISSION]`. You can revoke it after approval.

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
| 2 | Camera scanning a nutrition label | "Scan any nutrition label" |
| 3 | Scan result card with parsed data | "AI-powered accuracy" |
| 4 | Food Bank with saved items | "Save foods you eat often" |
| 5 | History view with charts | "See your trends over time" |
| 6 | Settings showing privacy features | "Your data stays yours" |

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
© 2025 Kevin C
```
