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

The app writes to Apple HealthKit (calories, protein, carbs, fat, fiber, sugar, sodium, cholesterol, saturated fat, and select vitamins/minerals) only when the user explicitly enables the toggle in Settings > Integrations. The app also reads active energy burned data from HealthKit to display daily calorie balance. HealthKit data is never sent to any external server.

The app provides nutrition citations and a full health disclaimer under Settings > Sources & Disclaimers, referencing FDA Daily Values (21 CFR §101.9) and noting that AI-estimated nutrition values are approximations.
```

**Important:** Before submitting, create a dedicated Gemini API key for the reviewer and paste it in place of `[PASTE YOUR REVIEW KEY HERE BEFORE SUBMISSION]`. You can revoke it after approval.

---

## Promotional Text (170 chars max, editable anytime — no review needed)

```
Scan any nutrition label or food photo with AI. Free, open-source, no account required. Your API key, your data, your privacy. Sync across devices with iCloud.
```

(160 chars)

**Seasonal alternatives:**
- New Year: `Start 2026 right — scan your meals, track your macros, own your data. Free AI-powered nutrition tracking with no subscriptions or accounts.`
- Feature launch: `NEW: Press-and-drag quick actions! Scan labels, log food, and track macros faster than ever. Free, open-source, no account needed.`

---

## What's New (version 1.0)

```
Welcome to OpenFoodJournal! 🎉

• AI-powered nutrition scanning — point your camera at a label or food photo
• 30+ micronutrients tracked automatically
• Personal Food Bank — save and re-log your favorite foods
• Container tracking — weigh your food for precise logging
• iCloud sync across all your devices
• Apple Health integration
• Interactive nutrition history charts
• Bring Your Own Key — you control your AI, your data, your privacy
```

---

## App Store Product Page Headlines

Apple allows up to 3 custom product pages (App Store Connect → App Store → Product Page Optimization). Each needs a headline and screenshot set.

### Default Product Page

**Headline:** `Scan Labels. Track Macros. Own Your Data.`

**Screenshot captions (in order):**
1. `Scan any label. Get instant macros.`
2. `Daily tracking at a glance.`
3. `Your Food Bank. One-tap logging.`
4. `Press, drag, done. Quick actions.`
5. `30+ nutrients from one photo.`
6. `Syncs everywhere via iCloud.`

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
1. `Point your camera. Done.`
2. `Photo your food. AI does the rest.`
3. `Powered by Gemini. Controlled by you.`
4. `Calories, protein, and 30+ nutrients.`
5. `Save favorites for one-tap logging.`

---

## Screenshot Strategy

Apple requires screenshots for each device size. Focus on iPhone 6.7" (iPhone 15 Pro Max) — smaller sizes auto-generate.

**Priority order for screenshots:**
1. **Scan in action** — camera pointed at a nutrition label with the ScanResultCard showing parsed macros
2. **Daily journal** — DailyLogView with macro rings filled, a few meal entries visible
3. **Food Bank** — list of saved foods with serving info
4. **Radial menu** — the + button with options fanned out (or the onboarding animation)
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
