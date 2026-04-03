# From Closed Database to Open: Integrating Open Food Facts into a SwiftUI Food Journal

A nutrition tracking app is only as useful as the foods it knows about. Until now, OpenFoodJournal relied entirely on users scanning labels or manually typing nutrition info. That works fine for your morning cereal, but falls apart when you're eating at a restaurant or buying something without a barcode. This session added Open Food Facts — a free, community-maintained database of 4 million+ food products — as a searchable data source inside the Food Bank.

## The Starting Point

OpenFoodJournal is a SwiftUI iOS app that uses AI (Gemini) to scan nutrition labels and log macros. Foods can be saved to a "Food Bank" for quick re-logging. The app follows a zero-dependency architecture: no SPM packages, no CocoaPods — just `URLSession`, SwiftData, and CloudKit.

The Food Bank had a gap: the only ways to add a food were scanning a physical label or typing everything manually. If you wanted to log a Chobani Greek Yogurt but didn't have the container in front of you, you were stuck. Open Food Facts fills that gap — it's like having every grocery store's nutrition aisle in your pocket.

**Open Food Facts (OFF)** is a Wikipedia-style open database where volunteers contribute food product data (nutrition facts, ingredients, barcodes). It has a free REST API with no authentication required for reads.

## Step 1: Understanding the OFF API's Quirks

The first surprise: Open Food Facts has *two* API versions, and they do different things.

**v2** (`/api/v2/search`) supports filtering by tags (category, brand, country) but **not full-text search**. If you want to search "greek yogurt," v2 can't help you.

**v1** (`/cgi/search.pl`) is the legacy search endpoint that *does* support full-text search. It's older but it's the only way to let users type a food name and get results.

So the architecture became: **v1 for text search, v2 for barcode lookup**.

```swift
// Text search uses the v1 API because v2 doesn't support full-text
var components = URLComponents(string: "\(baseURL)/cgi/search.pl")!
components.queryItems = [
    URLQueryItem(name: "search_terms", value: trimmed),
    URLQueryItem(name: "search_simple", value: "1"),
    URLQueryItem(name: "action", value: "process"),
    URLQueryItem(name: "json", value: "1"),
    URLQueryItem(name: "fields", value: requestFields),
    URLQueryItem(name: "page_size", value: "\(pageSize)"),
    URLQueryItem(name: "page", value: "\(page)")
]
```

The `fields` parameter is critical — OFF products can have dozens of fields (ingredients in 40 languages, eco-scores, packaging data). Requesting only `product_name,brands,nutriments,serving_size,serving_quantity,code` keeps responses small and parsing simple.

**Rate limits** are tight: 10 requests/minute for search, 100/minute for product reads. This drove the next design decision.

## Step 2: Debounced Search — Protecting Against Rate Limits

With a 10 req/min limit, firing a search on every keystroke would burn through the quota in seconds. The solution is a **debounced search** — wait for the user to stop typing before actually making the API call.

```swift
private func debouncedSearch(_ query: String) {
    // Cancel any pending search task
    searchTask?.cancel()
    
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        offService.searchResults = []
        return
    }
    
    searchTask = Task {
        // Wait 500ms — if another character is typed, this task gets cancelled
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        try? await offService.search(query: trimmed)
    }
}
```

The pattern: on each keystroke, cancel the previous `Task` and start a new one with a 500ms delay. If the user types "greek yogurt" quickly, only the final text triggers an API call. This keeps us well under the rate limit even for fast typists.

SwiftUI's `.searchable()` modifier provides the search bar UI for free, and `.onChange(of: searchText)` wires it to the debounce function. The total search UI is about 30 lines of view code.

## Step 3: The Mixed-Type JSON Problem

This was the most interesting technical challenge. OFF's `nutriments` object looks like this in the API response:

```json
{
  "nutriments": {
    "energy-kcal_100g": 150,
    "proteins_100g": 12.5,
    "carbohydrates_100g": "20",
    "fat_100g": 5.0,
    "nova-group": "4",
    "nutrition-score-fr": 3,
    "fiber_unit": "g"
  }
}
```

Notice: `carbohydrates_100g` is a **string** `"20"`, not a number. And there are non-numeric values like `"g"` mixed in. Swift's `Codable` expects consistent types — `[String: Double]` would crash on the string values.

The solution was a custom `AnyCodableValue` enum that tries each type and extracts the numeric value:

```swift
private enum AnyCodableValue: Codable {
    case string(String)
    case double(Double)
    case int(Int)
    case bool(Bool)
    
    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)  // Handles "20" → 20.0
        case .bool: return nil
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else { self = .string("") }
    }
}
```

In the custom `init(from:)` on `OFFRawProduct`, we decode the nutriments as `[String: AnyCodableValue]`, then filter to only the keys that parse as numbers:

```swift
if let rawNutriments = try container.decodeIfPresent(
    [String: AnyCodableValue].self, forKey: .nutriments
) {
    var nums: [String: Double] = [:]
    for (key, val) in rawNutriments {
        if let num = val.doubleValue {
            nums[key] = num
        }
    }
    nutriments = nums
}
```

This gracefully handles strings-that-are-numbers, actual numbers, and silently drops non-numeric metadata. No crashes, no data loss.

## The Gotcha: `lazy var` vs. `@Observable`

The first build attempt failed with a cryptic error about macro expansion.

I had defined the URLSession as a `lazy var` inside an `@Observable` class:

```swift
@Observable
final class OpenFoodFactsService {
    private lazy var session: URLSession = { ... }()
}
```

The `@Observable` macro transforms all stored properties to use its observation tracking system. But `lazy var` generates its own property wrapper internally, and the two conflict. The Swift compiler can't apply both transformations to the same property.

The fix is `@ObservationIgnored` — it tells the `@Observable` macro to leave this property alone:

```swift
@ObservationIgnored
private let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.httpAdditionalHeaders = [
        "User-Agent": "OpenFoodJournal/1.0 (openfoodjournal@example.com)"
    ]
    config.timeoutIntervalForRequest = 15
    return URLSession(configuration: config)
}()
```

This is actually the correct semantic choice anyway — `URLSession` is infrastructure, not observable state. Views don't need to re-render when the session changes (it never changes). The `@ObservationIgnored` annotation makes the intent explicit.

This mirrors an existing gotcha in the project where `UserGoals` uses `@ObservationIgnored` on `@AppStorage` properties for the same reason — two property-transforming systems can't coexist on the same variable.

## Step 4: The Per-100g to Per-Serving Math

OFF stores all nutrition values per 100g because that's the European standard. American users expect per-serving values. The math is simple but easy to get wrong:

```swift
var caloriesPerServing: Double {
    guard let grams = servingQuantityGrams, grams > 0 else {
        return caloriesPer100g  // Fallback: show per-100g if no serving info
    }
    return caloriesPer100g * grams / 100.0
}
```

The `servingQuantityGrams` comes from OFF's `serving_quantity` field, which is the numeric gram weight of one serving (e.g., `30` for a 30g cereal serving). When it's missing — and it often is, because OFF data quality varies — we fall back to per-100g values and label the serving size as "100g".

## Step 5: Fitting Into the Existing UI Pattern

The app already had a proven save flow in `ManualEntryView`: a toolbar `Menu` with "Add to Journal" and "Add to Journal & Food Bank" options. Rather than inventing a new pattern, the OFF detail sheet copies this exactly:

```swift
ToolbarItem(placement: .confirmationAction) {
    Menu {
        Button {
            save(saveToFoodBank: true)
        } label: {
            Label("Add to Journal & Food Bank", systemImage: "plus.circle.fill")
        }
        Button {
            save(saveToFoodBank: false)
        } label: {
            Label("Add to Journal", systemImage: "plus.circle")
        }
    } label: {
        Text("Add").fontWeight(.semibold)
    }
}
```

The Food Bank got a new "+" toolbar button to the left of the existing sort button. It's a `Menu` with two options: "Search Open Food Facts" and "Manual Entry." Both open sheets — no navigation push needed, which keeps the Food Bank's list context visible underneath.

The service injection follows the existing pattern too: `@State private var offService = OpenFoodFactsService()` in the app root, `.environment(offService)` on the view hierarchy, and `@Environment(OpenFoodFactsService.self)` in consuming views.

## What's Next

The contribute feature is wired up as a settings toggle but doesn't do anything yet — turning it on just stores a preference. Implementing the write side of the OFF API requires:
- User authentication (OFF accounts, stored in Keychain)
- A POST endpoint (`/cgi/product_jqm2.pl`) for submitting nutrition data
- UX for what gets submitted and when (after scan? after manual edit?)

Other potential improvements:
- **Barcode scan integration**: when the Gemini scan identifies a barcode, cross-reference with OFF to validate or supplement the AI's nutrition extraction
- **Offline caching**: save recently searched OFF products locally so they work without internet
- **Better pagination**: the current implementation loads 25 results; infinite scroll would let users browse deeper

---

*640 lines of code and one `lazy var` later, every grocery store shelf in the world is now searchable from the Food Bank tab.*
