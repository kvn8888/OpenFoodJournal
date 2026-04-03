# From 503 Errors to Barcode Scanning: Building a Full Open Food Facts Integration

When I first wired up Open Food Facts (OFF) — a free, open-source database of 3+ million food products — the search endpoint immediately returned a 503. That kicked off a session that spiraled from a simple API bug fix into a complete search UX overhaul, a barcode scanning system built on Apple's Vision framework, and a version-gated "What's New" sheet. Here's how each piece came together, what broke along the way, and what I'd do differently.

## The Starting Point

OpenFoodJournal is a SwiftUI food journaling app for iOS 26 that uses Gemini AI to scan nutrition labels and estimate food photos. The app already had a working camera pipeline (`ScanCaptureView` → `CameraController` → `ScanService` → Gemini REST API) and a Food Bank for saving frequently eaten foods.

The Open Food Facts integration was freshly added — an `OpenFoodFactsService` that searched the OFF API and displayed results in a custom detail sheet. But the first search attempt returned HTTP 503.

## Step 1: The 503 and the Two Open Food Facts APIs

**Goal**: Get search working.

**The symptom**: Every search request to `world.openfoodfacts.org/cgi/search.pl` returned 503. A quick `curl` confirmed it wasn't a code bug — the endpoint itself was rejecting requests.

**What I learned**: Open Food Facts has *two* search backends:

| Endpoint | Backend | Status |
|----------|---------|--------|
| `world.openfoodfacts.org/cgi/search.pl` | Legacy CGI/Perl | Returns 503 frequently |
| `search.openfoodfacts.org/search` | Elasticsearch | Stable, fast |

The Elasticsearch endpoint has different response shapes too. Instead of returning products directly with full nutrition data, it returns lightweight "hits" — just the product name, barcode, and brand:

```swift
// The Elasticsearch search API returns minimal data
struct OFFSearchRawHit: Codable {
    let code: String           // Barcode — the key for fetching full details
    let product_name: String?
    let brands: [String]?      // Array, not comma-separated string like v1
}
```

The `brands` field is an array of strings on the Elasticsearch API, but a comma-separated string on the main API. This is the kind of thing that silently breaks your Codable parsing if you assumed one shape and got the other.

**The fix**: Switch to `search.openfoodfacts.org`, then batch-fetch full product details by barcode for every search result. This two-step approach (search → batch fetch) is slightly slower but gets full nutrition data for display.

## Step 2: Batch Fetching with Swift Concurrency

**Goal**: After getting search hits (barcodes only), fetch full nutrition for all 25 results concurrently.

The naive approach would be a `for` loop with `await` on each fetch — 25 sequential network requests. Instead, I used `withTaskGroup` to fire them all concurrently:

```swift
func search(_ query: String) async {
    isLoading = true
    // Step 1: Get barcodes from Elasticsearch
    let hits = try await fetchSearchHits(query)
    
    // Step 2: Batch-fetch full products concurrently
    let products = await withTaskGroup(of: OFFProduct?.self) { group in
        for hit in hits {
            group.addTask { await self.fetchProductByBarcode(hit.code) }
        }
        var results: [OFFProduct] = []
        for await product in group {
            if let product { results.append(product) }
        }
        return results
    }
    
    searchResults = products
    isLoading = false
}
```

**The gotcha**: I originally had `defer { isLoading = false }` at the top of `search()`. That works fine for linear async functions, but `defer` fires when the *enclosing scope* exits — and with `withTaskGroup`, the timing gets subtle. The `defer` was firing before the task group completed its child tasks. I replaced it with explicit `isLoading = false` at each exit point.

**Architecture decision**: I split the barcode lookup into two methods — `lookupBarcode()` (public, manages `isLoading`/`errorMessage` state) and `fetchProductByBarcode()` (private, stateless). The batch search uses the stateless version so 25 concurrent fetches don't fight over shared `@Observable` state.

## Step 3: Making Search Results Look Native

**Goal**: OFF results should look identical to Food Bank items, not like a foreign data source.

The original implementation had a custom `OFFProductDetailSheet` with its own layout. The user wanted OFF products to feel like first-class citizens — same row layout as saved foods, same editing flow.

**Three changes**:

1. **Row layout**: Created `OFFProductRow` that mirrors `SavedFoodRowView` exactly — calorie count on the left (44pt column), brand/name/serving in the center, and P/C/F macro chips on the right with blue/green/yellow colors:

```swift
struct OFFProductRow: View {
    let product: OFFProduct
    
    var body: some View {
        HStack(spacing: 12) {
            // Calorie column — fixed width for alignment
            Text("\(Int(product.calories))")
                .font(.headline.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
            
            // Name + brand + serving
            VStack(alignment: .leading) {
                Text(product.name).font(.subheadline.weight(.medium))
                if let brand = product.brand {
                    Text(brand).font(.caption).foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // P / C / F chips
            MacroChip("P", value: product.protein, color: .blue)
            MacroChip("C", value: product.carbs, color: .green)
            MacroChip("F", value: product.fat, color: .yellow)
        }
    }
}
```

2. **Search trigger**: Removed per-keystroke debounced search. Added `.onSubmit(of: .search)` so search only fires on Enter. This is cleaner UX and avoids hammering the API on every character.

3. **Detail view**: Instead of a custom detail sheet, tapping a product opens `ManualEntryView` — the same form users already know for logging food. Added a `prefillProduct: OFFProduct?` parameter that pre-fills all fields on `.onAppear`:

```swift
.onAppear {
    guard let product = prefillProduct else { return }
    foodName = product.name
    brand = product.brand ?? ""
    calories = formatValue(product.calories)
    protein = formatValue(product.protein)
    carbs = formatValue(product.carbs)
    fat = formatValue(product.fat)
    // ... micronutrients too
    focusedField = nil  // Don't auto-focus keyboard for pre-filled entries
}
```

## Step 4: Barcode Scanning — Reusing the Camera Pipeline

**Goal**: Add barcode scanning as a third camera mode alongside "Scan Label" and "Scan Food Photo."

**Design decision**: I had three options for barcode detection:

| Approach | Pros | Cons |
|----------|------|------|
| `AVCaptureMetadataOutput` | Real-time detection, no capture needed | Complex setup, different from existing photo flow |
| `DataScannerViewController` (VisionKit) | Apple's built-in scanner UI | Wrapping UIKit in SwiftUI, own UI chrome |
| `VNDetectBarcodesRequest` (Vision) | Works on any `CGImage`, reuses existing capture flow | Requires photo capture first |

I chose Vision's `VNDetectBarcodesRequest` because it reuses the existing capture → review → action flow. The user takes a photo (same as label/food scanning), then instead of "Analyze" (Gemini), they tap "Look Up" which runs barcode detection locally and looks up the result on OFF.

**Implementation**:

1. Added `ScanMode.barcode` to the enum (which immediately caused exhaustive-switch build errors in `LogFoodSheet` — the compiler caught what I'd have missed):

```swift
enum ScanMode: String, Codable, CaseIterable {
    case label = "Label Scan"
    case foodPhoto = "Food Photo"
    case barcode = "Barcode"
    case manual = "Manual"
}
```

2. Added a third `ScanModeCard` to the mode selection overlay — orange, with `barcode.viewfinder` icon.

3. The detection → lookup → pre-fill pipeline:

```swift
private func detectAndLookupBarcode(from image: UIImage) async {
    guard let cgImage = image.cgImage else { return }
    
    // Step 1: Vision framework barcode detection (runs locally, no network)
    let request = VNDetectBarcodesRequest()
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try handler.perform([request])
    
    guard let barcode = request.results?.first?.payloadStringValue else {
        offService.errorMessage = "No barcode detected. Try again with the barcode clearly visible."
        return
    }
    
    // Step 2: OFF API lookup
    guard let product = try? await offService.lookupBarcode(barcode) else { return }
    
    // Step 3: Open ManualEntryView pre-filled with product data
    barcodeProduct = product  // triggers .sheet(item:)
}
```

**What I like about this approach**: The user gets to *see* the photo they took and explicitly tap "Look Up" before anything happens. No magic, no surprise network calls. And if the barcode isn't detected, they can retake immediately.

## The Gotcha: Exhaustive Switches and Pre-existing Bugs

Adding a new enum case to `ScanMode` was a textbook example of Swift's exhaustive switch checking earning its keep. The compiler immediately flagged two switches in `LogFoodSheet` that needed the new `.barcode` case.

But the *interesting* bug was one I didn't create. While fixing the build, I hit an error in `FoodNutrientBreakdownView.swift`:

```
error: type 'KnownMicronutrient.Category' has no member 'vitamins'
```

The enum defines `.vitamin` (singular), but this file referenced `.vitamins` (plural). It had been broken before my changes — likely from a recent rename that missed this file. The raw values *are* plural (`"Vitamins"`, `"Minerals"`), which makes the mismatch easy to make. I added this as gotcha #16 in the project skill so future agents don't waste time on it.

## Step 5: The What's New Sheet

**Goal**: Since this is a v1.1 release with several user-facing features, show a "What's New" sheet once after update.

**Pattern**: `@AppStorage("lastSeenVersion")` in `ContentView` compared against `CFBundleShortVersionString`. On mismatch, present the sheet. On dismiss, update the stored version. Simple, no server needed, survives app reinstalls via UserDefaults backup.

```swift
.onAppear {
    if lastSeenVersion != currentVersion {
        showWhatsNew = true
    }
}
.sheet(isPresented: $showWhatsNew, onDismiss: {
    lastSeenVersion = currentVersion
}) {
    WhatsNewSheet()
}
```

Each feature is a `FeatureRow` with an SF Symbol, accent color, title, and description. Adding features for v1.2 is just adding rows and bumping the version header text.

## What I'd Do Differently

1. **Real-time barcode scanning**: The current "take a photo → detect" flow works, but real-time detection via `AVCaptureMetadataOutput` would feel more polished. The camera could show a bounding box around detected barcodes in the viewfinder, and auto-trigger lookup without a capture step. I avoided it to keep the implementation simple and reuse the existing camera pipeline, but it's the obvious next iteration.

2. **Search pagination**: The current implementation fetches 25 results and stops. OFF's Elasticsearch API supports pagination, but batch-fetching full details for page 2 means another 25 network requests. A "load more" button at the bottom of results would be a nice UX addition.

3. **Offline barcode cache**: Products don't change often. Caching OFF lookups locally (even just in-memory for the session) would make repeated scans of the same product instant.

4. **The `defer` vs `withTaskGroup` issue**: I should have known `defer` and structured concurrency don't always play well together. The lesson is simple — if your function uses `withTaskGroup` or any scope that outlives the `defer`'s natural exit, manage state explicitly.

---

*Sometimes the best debugging insight is realizing the endpoint you're calling isn't the one the documentation recommends. The OFF v1 CGI endpoint returning 503 wasn't a bug in my code — it was a nudge toward their better, newer infrastructure. Every integration has that moment where "my code is wrong" becomes "their API isn't what I expected."*
