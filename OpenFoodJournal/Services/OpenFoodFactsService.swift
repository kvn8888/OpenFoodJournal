// OpenFoodJournal — OpenFoodFactsService
// Handles all communication with the Open Food Facts REST API.
// Provides text-based food search and barcode lookup, returning
// structured product data that can be converted to NutritionEntry / SavedFood.
//
// Architecture notes:
// - Uses URLSession directly (no SPM dependencies) to match project conventions
// - Text search uses the dedicated search API (search.openfoodfacts.org) —
//   the v1 CGI endpoint is deprecated/unstable and the v2 API doesn't support full-text search
// - Search returns lightweight hits (name, brand, code); full nutrition loaded on demand
// - Barcode/product lookup uses v2 API (/api/v2/product/{barcode})
// - All nutrition values from OFF are per 100g; serving-based values derived from serving_size field
// - Rate limits: 10 req/min for search, 100 req/min for product reads
// - User-Agent header required by OFF API policy
//
// AGPL-3.0 License

import Foundation

// MARK: - OFFProduct

/// Represents a single product from the Open Food Facts database.
/// Contains the subset of fields we request from the API (nutrition, serving, identification).
/// This is a local struct — NOT a SwiftData model. It's a transient DTO that gets
/// converted to NutritionEntry or SavedFood when the user decides to save it.
struct OFFProduct: Identifiable, Sendable {
    /// Barcode (EAN/UPC) — used as the unique identifier
    let code: String
    /// Product name as entered by OFF contributors
    let name: String
    /// Brand name (may be nil if not recorded)
    let brand: String?
    /// Calories per 100g
    let caloriesPer100g: Double
    /// Protein grams per 100g
    let proteinPer100g: Double
    /// Carbohydrate grams per 100g
    let carbsPer100g: Double
    /// Fat grams per 100g
    let fatPer100g: Double
    /// Human-readable serving size string from OFF (e.g. "30g", "1 cup (240ml)")
    let servingSize: String?
    /// Serving quantity in grams (parsed from serving_size when available)
    let servingQuantityGrams: Double?
    /// Micronutrients extracted from OFF nutriments object
    let micronutrients: [String: MicronutrientValue]

    /// Identifiable conformance — barcode is unique per product
    var id: String { code }

    // MARK: - Serving-Scaled Values

    /// Returns calories for one serving (if serving info available), otherwise per 100g
    var caloriesPerServing: Double {
        guard let grams = servingQuantityGrams, grams > 0 else { return caloriesPer100g }
        return caloriesPer100g * grams / 100.0
    }

    /// Returns protein for one serving (if serving info available), otherwise per 100g
    var proteinPerServing: Double {
        guard let grams = servingQuantityGrams, grams > 0 else { return proteinPer100g }
        return proteinPer100g * grams / 100.0
    }

    /// Returns carbs for one serving (if serving info available), otherwise per 100g
    var carbsPerServing: Double {
        guard let grams = servingQuantityGrams, grams > 0 else { return carbsPer100g }
        return carbsPer100g * grams / 100.0
    }

    /// Returns fat for one serving (if serving info available), otherwise per 100g
    var fatPerServing: Double {
        guard let grams = servingQuantityGrams, grams > 0 else { return fatPer100g }
        return fatPer100g * grams / 100.0
    }
}

// MARK: - OFFSearchHit

/// Lightweight search result from the Open Food Facts search API.
/// Contains only identification data (name, brand, barcode) — no nutrition.
/// Full nutrition is fetched on demand via barcode lookup when the user taps a result.
struct OFFSearchHit: Identifiable, Sendable, Hashable {
    /// Barcode (EAN/UPC)
    let code: String
    /// Product name
    let name: String
    /// Brand name (may be nil)
    let brand: String?

    var id: String { code }
}

// MARK: - OpenFoodFactsService

/// Service that communicates with the Open Food Facts REST API.
/// Created once in MacrosApp.init() and injected via .environment().
/// All methods are async and throw on network/parse errors.
@Observable
@MainActor
final class OpenFoodFactsService {

    // ── Published State ───────────────────────────────────────────
    /// Lightweight results from the most recent search query (name/brand/code only)
    var searchResults: [OFFSearchHit] = []
    /// Whether a network request is currently in flight
    var isLoading = false
    /// User-facing error message from the last failed request
    var errorMessage: String?
    /// Total number of products matching the last search query (for pagination context)
    var totalResultCount = 0

    // ── Configuration ─────────────────────────────────────────────

    /// Base URL for product lookups via the main OFF API
    private let baseURL = "https://world.openfoodfacts.org"

    /// Base URL for the dedicated search service (Elasticsearch-backed)
    private let searchBaseURL = "https://search.openfoodfacts.org"

    /// User-Agent string required by OFF API policy.
    /// Format: AppName/Version (ContactEmail)
    private let userAgent = "OpenFoodJournal/1.0 (openfoodjournal@example.com)"

    /// Fields to request from the OFF API — limits response size and parse complexity.
    /// nutriments contains all nutrition data; serving_size/serving_quantity for portion math.
    private let requestFields = "product_name,brands,nutriments,serving_size,serving_quantity,code"

    /// Max results per search page — 25 is a good balance between density and response time
    private let pageSize = 25

    // ── Shared URLSession ─────────────────────────────────────────
    /// Session with the required User-Agent header.
    /// @ObservationIgnored because URLSession is not observable state —
    /// it's infrastructure that doesn't need to trigger view updates.
    @ObservationIgnored
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "OpenFoodJournal/1.0 (openfoodjournal@example.com)"
        ]
        // 15-second timeout prevents the UI from hanging on slow networks
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    // MARK: - Text Search

    /// Searches Open Food Facts for products matching a text query.
    /// Uses the dedicated search service (search.openfoodfacts.org) which is
    /// Elasticsearch-backed and more reliable than the legacy v1 CGI endpoint.
    /// Returns lightweight hits (name/brand/code) — full nutrition is loaded on demand.
    ///
    /// - Parameters:
    ///   - query: The user's search text (e.g. "greek yogurt", "cheerios")
    ///   - page: 1-based page number for pagination (default: 1)
    /// - Throws: URLError on network failure, or a descriptive error on parse failure
    func search(query: String, page: Int = 1) async throws {
        // Don't search for empty or whitespace-only strings
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            totalResultCount = 0
            return
        }

        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        // Build the search URL using the dedicated search service
        // q= is the search query, page/page_size for pagination
        // fields= limits the response to just what we need for the list
        var components = URLComponents(string: "\(searchBaseURL)/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "fields", value: "product_name,brands,code"),
            URLQueryItem(name: "page_size", value: "\(pageSize)"),
            URLQueryItem(name: "page", value: "\(page)")
        ]

        guard let url = components.url else {
            errorMessage = "Invalid search URL"
            return
        }

        do {
            let (data, response) = try await session.data(from: url)

            // Check for HTTP errors (rate limiting returns 429, server errors return 5xx)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                errorMessage = "Server returned \(httpResponse.statusCode)"
                return
            }

            // Parse the JSON response — search API uses "hits" instead of "products"
            let searchResponse = try JSONDecoder().decode(OFFSearchResult.self, from: data)
            totalResultCount = searchResponse.page_count

            // Convert each hit into our clean OFFSearchHit struct
            searchResults = searchResponse.hits.compactMap { hit in
                // Must have a product name to be useful
                let name = hit.product_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !name.isEmpty else { return nil }

                // Brands come as an array from the search API — take the first
                let brand = hit.brands?.first?.trimmingCharacters(in: .whitespacesAndNewlines)

                return OFFSearchHit(
                    code: hit.code ?? "",
                    name: name,
                    brand: brand
                )
            }
        } catch let error as DecodingError {
            errorMessage = "Failed to parse response"
            print("OFF decode error: \(error)")
        } catch {
            errorMessage = "Network error: \(error.localizedDescription)"
        }
    }

    // MARK: - Product Detail Fetch

    /// Fetches full product details (including nutrition) for a search hit.
    /// Called when the user taps a search result to see the detail sheet.
    ///
    /// - Parameter hit: The lightweight search hit to fetch full details for
    /// - Returns: A full OFFProduct with nutrition data, or nil if fetch failed
    func fetchProduct(for hit: OFFSearchHit) async -> OFFProduct? {
        guard !hit.code.isEmpty else {
            errorMessage = "No barcode available"
            return nil
        }
        return try? await lookupBarcode(hit.code)
    }

    // MARK: - Barcode Lookup

    /// Looks up a single product by its barcode using the v2 API.
    /// Returns nil if the product isn't in the OFF database.
    ///
    /// - Parameter barcode: EAN-13, UPC-A, or other barcode string
    /// - Returns: The matching OFFProduct, or nil if not found
    func lookupBarcode(_ barcode: String) async throws -> OFFProduct? {
        let trimmed = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // v2 barcode endpoint — cleaner JSON structure than v1
        var components = URLComponents(string: "\(baseURL)/api/v2/product/\(trimmed)")!
        components.queryItems = [
            URLQueryItem(name: "fields", value: requestFields)
        ]

        guard let url = components.url else {
            errorMessage = "Invalid barcode URL"
            return nil
        }

        do {
            let (data, response) = try await session.data(from: url)

            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                errorMessage = "Product not found"
                return nil
            }

            let productResponse = try JSONDecoder().decode(OFFProductResponse.self, from: data)

            // OFF returns status=0 when product isn't found (even with 200 HTTP status)
            guard productResponse.status == 1,
                  let rawProduct = productResponse.product else {
                return nil
            }

            return parseProduct(rawProduct)
        } catch {
            errorMessage = "Lookup failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Product → NutritionEntry Conversion

    /// Converts an OFFProduct to a NutritionEntry ready for journal logging.
    /// Uses per-serving values when available, otherwise per-100g.
    ///
    /// - Parameters:
    ///   - product: The OFF product to convert
    ///   - mealType: Which meal to assign the entry to
    /// - Returns: A new NutritionEntry (NOT yet inserted into SwiftData)
    static func toNutritionEntry(_ product: OFFProduct, mealType: MealType = .snack) -> NutritionEntry {
        NutritionEntry(
            name: product.name,
            mealType: mealType,
            scanMode: .manual,
            calories: product.caloriesPerServing,
            protein: product.proteinPerServing,
            carbs: product.carbsPerServing,
            fat: product.fatPerServing,
            micronutrients: product.micronutrients,
            servingSize: product.servingSize ?? "100g",
            brand: product.brand
        )
    }

    /// Converts an OFFProduct to a SavedFood for the Food Bank.
    ///
    /// - Parameter product: The OFF product to convert
    /// - Returns: A new SavedFood (NOT yet inserted into SwiftData)
    static func toSavedFood(_ product: OFFProduct) -> SavedFood {
        SavedFood(
            name: product.name,
            brand: product.brand,
            calories: product.caloriesPerServing,
            protein: product.proteinPerServing,
            carbs: product.carbsPerServing,
            fat: product.fatPerServing,
            micronutrients: product.micronutrients,
            servingSize: product.servingSize ?? "100g",
            originalScanMode: .manual
        )
    }

    // MARK: - Private Parsing

    /// Maps an OFF API raw product dictionary to our clean OFFProduct struct.
    /// Handles missing/malformed data gracefully — returns nil only if name is missing.
    private func parseProduct(_ raw: OFFRawProduct) -> OFFProduct? {
        // Product must have a name to be useful
        let name = raw.product_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }

        // Extract brand — OFF stores it as a comma-separated string
        let brand = raw.brands?.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract core macros from nutriments — all are per 100g
        let nutriments = raw.nutriments ?? [:]
        let calories = nutriments["energy-kcal_100g"] ?? nutriments["energy-kcal"] ?? 0
        let protein = nutriments["proteins_100g"] ?? nutriments["proteins"] ?? 0
        let carbs = nutriments["carbohydrates_100g"] ?? nutriments["carbohydrates"] ?? 0
        let fat = nutriments["fat_100g"] ?? nutriments["fat"] ?? 0

        // Parse serving quantity — OFF provides this as grams
        let servingQty = raw.serving_quantity

        // Extract micronutrients from the nutriments dictionary
        let micros = parseMicronutrients(from: nutriments)

        return OFFProduct(
            code: raw.code ?? "",
            name: name,
            brand: brand,
            caloriesPer100g: calories,
            proteinPer100g: protein,
            carbsPer100g: carbs,
            fatPer100g: fat,
            servingSize: raw.serving_size,
            servingQuantityGrams: servingQty,
            micronutrients: micros
        )
    }

    /// Extracts known micronutrients from the OFF nutriments dictionary.
    /// Maps OFF field names (e.g. "fiber_100g") to our canonical nutrient names.
    private func parseMicronutrients(from nutriments: [String: Double]) -> [String: MicronutrientValue] {
        // Mapping from OFF nutriment keys to our canonical names + units
        let offToCanonical: [(offKey: String, name: String, unit: String)] = [
            ("fiber_100g", "Fiber", "g"),
            ("sugars_100g", "Sugar", "g"),
            ("sodium_100g", "Sodium", "mg"),        // OFF stores in g, we display mg
            ("saturated-fat_100g", "Saturated Fat", "g"),
            ("trans-fat_100g", "Trans Fat", "g"),
            ("cholesterol_100g", "Cholesterol", "mg"),
            ("vitamin-a_100g", "Vitamin A", "mcg"),
            ("vitamin-c_100g", "Vitamin C", "mg"),
            ("calcium_100g", "Calcium", "mg"),
            ("iron_100g", "Iron", "mg"),
            ("potassium_100g", "Potassium", "mg"),
            ("vitamin-d_100g", "Vitamin D", "mcg"),
        ]

        var result: [String: MicronutrientValue] = [:]

        for mapping in offToCanonical {
            if let value = nutriments[mapping.offKey], value > 0 {
                var adjustedValue = value
                // OFF stores sodium in grams; our app displays in mg
                if mapping.offKey == "sodium_100g" || mapping.offKey == "cholesterol_100g" {
                    adjustedValue = value * 1000
                }
                result[mapping.name] = MicronutrientValue(value: adjustedValue, unit: mapping.unit)
            }
        }

        return result
    }
}

// MARK: - Codable Response Types

/// Wrapper for the search.openfoodfacts.org response.
/// Contains pagination info and an array of lightweight hit objects.
private struct OFFSearchResult: Codable {
    /// Total number of matching products across all pages
    let page_count: Int
    /// Current page number
    let page: Int
    /// Number of results per page
    let page_size: Int
    /// Array of search result hits (lightweight — no nutrition data)
    let hits: [OFFSearchRawHit]
}

/// Raw hit from the search API — just name, brands (array), and barcode.
private struct OFFSearchRawHit: Codable {
    let code: String?
    let product_name: String?
    /// Brands come as a string array from the search API (unlike the main API's comma-separated string)
    let brands: [String]?
}

/// Wrapper for the v2 barcode lookup API response.
/// Status 1 = found, 0 = not found.
private struct OFFProductResponse: Codable {
    let code: String
    let status: Int
    let product: OFFRawProduct?
}

/// Raw product data from the OFF API — maps directly to the JSON structure.
/// We use optional doubles for nutriments because OFF data quality varies;
/// many products have partial nutrition info.
private struct OFFRawProduct: Codable {
    let code: String?
    let product_name: String?
    let brands: String?
    let serving_size: String?
    let serving_quantity: Double?
    let nutriments: [String: Double]?

    /// Custom decoding because the nutriments object contains mixed types
    /// (strings and numbers). We only care about the numeric values.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        product_name = try container.decodeIfPresent(String.self, forKey: .product_name)
        brands = try container.decodeIfPresent(String.self, forKey: .brands)
        serving_size = try container.decodeIfPresent(String.self, forKey: .serving_size)
        serving_quantity = try container.decodeIfPresent(Double.self, forKey: .serving_quantity)

        // Decode nutriments manually — the dict has mixed String/Number values
        // We only want the numeric ones for nutrition calculations
        if let rawNutriments = try container.decodeIfPresent([String: AnyCodableValue].self, forKey: .nutriments) {
            var nums: [String: Double] = [:]
            for (key, val) in rawNutriments {
                if let num = val.doubleValue {
                    nums[key] = num
                }
            }
            nutriments = nums
        } else {
            nutriments = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case code, product_name, brands, serving_size, serving_quantity, nutriments
    }
}

/// Helper to decode OFF nutriments which contain mixed types (strings and numbers).
/// We extract only the Double values and discard string metadata (units, labels).
private enum AnyCodableValue: Codable {
    case string(String)
    case double(Double)
    case int(Int)
    case bool(Bool)

    /// Extracts the numeric value regardless of whether it was encoded as int or double
    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s) // Sometimes numbers are encoded as strings
        case .bool: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Try types in order of likelihood for nutrition data
        if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else {
            self = .string("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .double(let d): try container.encode(d)
        case .int(let i): try container.encode(i)
        case .bool(let b): try container.encode(b)
        }
    }
}
