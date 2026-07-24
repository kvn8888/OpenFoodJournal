// OpenFoodJournal — Assistant Tool Registry
// Declares the function-calling tools the Assistant agent can use, in a
// provider-neutral form rendered to Gemini (uppercase schema types) or
// OpenAI/OpenRouter (lowercase) formats. Execution lives in ChatService.
// AGPL-3.0 License

import Foundation

// MARK: - JSONValue

/// Minimal arbitrary-JSON representation for tool arguments, results, and
/// schemas. Codable so it can ride inside typed request/response structs.
nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Accessors

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    // MARK: Serialization

    static func parse(_ jsonString: String) -> JSONValue? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// Deterministic provider-neutral guardrail for tool payloads. Explicit
/// markers prevent a model from mistaking a bounded result for a complete one.
nonisolated enum ChatToolResultLimiter {
    static func limit(
        _ value: JSONValue,
        maximumStringCharacters: Int = 8_000,
        maximumArrayItems: Int = 120,
        maximumObjectKeys: Int = 100,
        maximumDepth: Int = 10
    ) -> JSONValue {
        func walk(_ value: JSONValue, depth: Int) -> JSONValue {
            guard depth <= maximumDepth else {
                return .object([
                    "_truncated": .bool(true),
                    "reason": .string("maximum JSON depth exceeded"),
                ])
            }
            switch value {
            case .string(let string):
                guard string.count > maximumStringCharacters else { return value }
                let omitted = string.count - maximumStringCharacters
                return .string(
                    String(string.prefix(maximumStringCharacters))
                        + "\n[truncated \(omitted) characters]"
                )
            case .array(let values):
                var limited = values.prefix(maximumArrayItems).map { walk($0, depth: depth + 1) }
                if values.count > maximumArrayItems {
                    limited.append(.object([
                        "_truncated": .bool(true),
                        "omitted_items": .number(Double(values.count - maximumArrayItems)),
                    ]))
                }
                return .array(limited)
            case .object(let object):
                let keys = object.keys.sorted()
                var limited = Dictionary(uniqueKeysWithValues: keys.prefix(maximumObjectKeys).compactMap { key in
                    object[key].map { (key, walk($0, depth: depth + 1)) }
                })
                if keys.count > maximumObjectKeys {
                    limited["_truncated"] = .bool(true)
                    limited["_omitted_keys"] = .number(Double(keys.count - maximumObjectKeys))
                }
                return .object(limited)
            case .number, .bool, .null:
                return value
            }
        }
        return walk(value, depth: 0)
    }
}

// MARK: - Tool Specs

nonisolated struct ChatToolSpec: Sendable {
    let name: String
    let description: String
    /// Lowercase JSON-schema object for parameters; nil when the tool takes none.
    let parameters: JSONValue?
    /// Write tools require a user permission card before execution.
    let isWrite: Bool
}

nonisolated enum ChatToolRegistry {
    // Shorthand schema builders keep the spec table readable.
    private static func obj(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .object(schema)
    }

    private static func str(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func num(_ description: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(description)])
    }

    private static func arr(_ description: String, items: JSONValue) -> JSONValue {
        .object(["type": .string("array"), "description": .string(description), "items": items])
    }

    private static let mealEnum: JSONValue = .object([
        "type": .string("string"),
        "description": .string("Meal type"),
        "enum": .array([.string("Breakfast"), .string("Lunch"), .string("Dinner"), .string("Snack")]),
    ])

    private static let portionSchema: JSONValue = obj([
        "label": str("Portion label, e.g. \"1 scoop\", \"6\\\" sub\", \"footlong\""),
        "calories": num("Calories for this portion"),
        "protein": num("Protein grams"),
        "carbs": num("Carb grams"),
        "fat": num("Fat grams"),
        "micronutrients": arr(
            "Optional micronutrients for this portion. Include every reliably known nutrient; do not invent missing values.",
            items: micronutrientSchema
        ),
    ], required: ["label", "calories", "protein", "carbs", "fat"])

    private static let ingredientSchema: JSONValue = obj([
        "name": str("Ingredient name, e.g. \"Turkey\", \"Provolone\", \"White roll\""),
        "note": str("Optional note about the ingredient"),
        "portions": arr("Portion options with their nutrition", items: portionSchema),
    ], required: ["name", "portions"])

    private static let micronutrientSchema: JSONValue = obj([
        "name": str("Nutrient name or canonical ID, e.g. \"Calcium\", \"vitamin_b12\", or \"fiber\""),
        "value": num("Numeric amount per serving"),
        "unit": str("Unit exactly as measured, e.g. \"mg\", \"mcg\", \"g\", \"IU\", or \"%DV\""),
    ], required: ["name", "value", "unit"])

    /// The complete tool catalog. Order matters only for readability.
    static let all: [ChatToolSpec] = [
        // MARK: Reads
        ChatToolSpec(
            name: "get_daily_summary",
            description: "Get calorie/macro totals, goals, remaining budget, and the list of logged foods for one day.",
            parameters: obj(["date": str("Date as YYYY-MM-DD. Omit for today.")]),
            isWrite: false
        ),
        ChatToolSpec(
            name: "query_entries",
            description: "List logged journal entries over a date range, optionally filtered by meal. Use for multi-day analysis and trends.",
            parameters: obj([
                "start_date": str("Start date as YYYY-MM-DD (inclusive)"),
                "end_date": str("End date as YYYY-MM-DD (inclusive)"),
                "meal": mealEnum,
            ], required: ["start_date", "end_date"]),
            isWrite: false
        ),
        ChatToolSpec(
            name: "search_food_bank",
            description: "Search the user's saved foods (Food Bank) by name or brand. Returns calories, macros, all stored micronutrients, serving information, and food IDs.",
            parameters: obj(["query": str("Search text matched against food name and brand")], required: ["query"]),
            isWrite: false
        ),
        ChatToolSpec(
            name: "get_goals",
            description: "Get the user's daily calorie and macro goals.",
            parameters: nil,
            isWrite: false
        ),
        ChatToolSpec(
            name: "get_active_energy",
            description: "Get active energy burned (kcal) from Apple Health for one day, if the user granted access.",
            parameters: obj(["date": str("Date as YYYY-MM-DD. Omit for today.")]),
            isWrite: false
        ),
        ChatToolSpec(
            name: "list_calculators",
            description: "List the user's nutrition calculators (build-your-own-meal templates, e.g. a sandwich shop menu).",
            parameters: nil,
            isWrite: false
        ),
        ChatToolSpec(
            name: "get_calculator",
            description: "Get one nutrition calculator with all ingredients and portion options.",
            parameters: obj(["calculator_id": str("Calculator UUID from list_calculators or search_food_bank")], required: ["calculator_id"]),
            isWrite: false
        ),
        ChatToolSpec(
            name: "web_search",
            description: "Search the web for current information and return source URLs with relevant evidence. For broad research, include 2-3 concise keyword search_queries in addition to the self-contained query.",
            parameters: obj([
                "query": str("Self-contained research objective or question"),
                "search_queries": arr(
                    "Optional 2-3 diverse keyword queries, ideally 3-6 words each",
                    items: str("One concise keyword query")
                ),
            ], required: ["query"]),
            isWrite: false
        ),
        ChatToolSpec(
            name: "fetch_url",
            description: "Download a URL the user provided or that a web search surfaced. PDFs and images are attached to the conversation for you to read directly; HTML is returned as extracted text.",
            parameters: obj(["url": str("The http(s) URL to fetch")], required: ["url"]),
            isWrite: false
        ),
        ChatToolSpec(
            name: "read_conversation_source",
            description: "Re-open a durable source from this conversation by source_id after it has left the active context or been compacted. Returns cached text or reattaches the saved PDF/image.",
            parameters: obj([
                "source_id": str("Source UUID returned by web_search or fetch_url"),
            ], required: ["source_id"]),
            isWrite: false
        ),
        ChatToolSpec(
            name: "get_nutrition_context",
            description: "Get one day's journal totals, goals, remaining budget, entries, aggregated micronutrients, and optionally Apple Health active energy in one call. Prefer this over several sequential reads when these facts are needed together.",
            parameters: obj([
                "date": str("Date as YYYY-MM-DD. Omit for today."),
                "include_active_energy": .object([
                    "type": .string("boolean"),
                    "description": .string("Whether to include Apple Health active energy"),
                ]),
            ]),
            isWrite: false
        ),

        // MARK: Writes (permission-gated)
        ChatToolSpec(
            name: "log_entry",
            description: "Log a food with macros and any known micronutrients to the user's journal. Requires user approval. Use realistic estimates and say so when estimating.",
            parameters: obj([
                "name": str("Food name"),
                "calories": num("Calories"),
                "protein": num("Protein grams"),
                "carbs": num("Carb grams"),
                "fat": num("Fat grams"),
                "micronutrients": arr("Optional micronutrients. Include every reliably known nutrient; do not invent missing values.", items: micronutrientSchema),
                "meal": mealEnum,
                "date": str("Date as YYYY-MM-DD. Omit for today."),
                "brand": str("Optional brand or restaurant"),
                "serving_description": str("Optional serving label, e.g. \"2 eggs\", \"1 cup\""),
            ], required: ["name", "calories", "protein", "carbs", "fat", "meal"]),
            isWrite: true
        ),
        ChatToolSpec(
            name: "update_entry",
            description: "Update fields on an existing journal entry. Requires user approval. Only include fields to change.",
            parameters: obj([
                "entry_id": str("Entry UUID from get_daily_summary or query_entries"),
                "name": str("New name"),
                "calories": num("New calories"),
                "protein": num("New protein grams"),
                "carbs": num("New carb grams"),
                "fat": num("New fat grams"),
                "meal": mealEnum,
                "brand": str("New brand"),
                "micronutrients": arr("Micronutrients to add or replace by canonical nutrient name. Existing nutrients not listed are preserved.", items: micronutrientSchema),
                "remove_micronutrients": arr("Nutrient names or canonical IDs to remove", items: str("Nutrient name or canonical ID")),
            ], required: ["entry_id"]),
            isWrite: true
        ),
        ChatToolSpec(
            name: "delete_entry",
            description: "Delete a journal entry. Requires user approval.",
            parameters: obj(["entry_id": str("Entry UUID")], required: ["entry_id"]),
            isWrite: true
        ),
        ChatToolSpec(
            name: "save_food",
            description: "Save a reusable food template, including any known micronutrients, to the user's Food Bank. Requires user approval.",
            parameters: obj([
                "name": str("Food name"),
                "calories": num("Calories per serving"),
                "protein": num("Protein grams per serving"),
                "carbs": num("Carb grams per serving"),
                "fat": num("Fat grams per serving"),
                "micronutrients": arr("Optional micronutrients per serving. Include every reliably known nutrient; do not invent missing values.", items: micronutrientSchema),
                "brand": str("Optional brand or restaurant"),
                "serving_description": str("Optional serving label"),
            ], required: ["name", "calories", "protein", "carbs", "fat"]),
            isWrite: true
        ),
        ChatToolSpec(
            name: "log_saved_food",
            description: "Log an existing Food Bank item by food ID while preserving and proportionally scaling its macros and micronutrients. Requires user approval.",
            parameters: obj([
                "food_id": str("Food UUID from search_food_bank"),
                "quantity": num("Optional amount to log. Defaults to the saved serving quantity."),
                "unit": str("Optional serving unit. Defaults to the saved serving unit."),
                "meal": mealEnum,
                "date": str("Date as YYYY-MM-DD. Omit for today."),
            ], required: ["food_id", "meal"]),
            isWrite: true
        ),
        ChatToolSpec(
            name: "update_food",
            description: "Update fields on an existing Food Bank item, including micronutrients. Requires user approval. Only include fields to change.",
            parameters: obj([
                "food_id": str("Food UUID from search_food_bank"),
                "name": str("New food name"),
                "brand": str("New brand"),
                "calories": num("New calories per saved serving"),
                "protein": num("New protein grams per saved serving"),
                "carbs": num("New carb grams per saved serving"),
                "fat": num("New fat grams per saved serving"),
                "serving_description": str("New serving label"),
                "micronutrients": arr("Micronutrients to add or replace by canonical nutrient name. Existing nutrients not listed are preserved.", items: micronutrientSchema),
                "remove_micronutrients": arr("Nutrient names or canonical IDs to remove", items: str("Nutrient name or canonical ID")),
            ], required: ["food_id"]),
            isWrite: true
        ),
        ChatToolSpec(
            name: "update_goals",
            description: "Change the user's daily calorie/macro goals. Requires user approval. Only include goals to change.",
            parameters: obj([
                "calories": num("New daily calorie goal"),
                "protein": num("New daily protein goal (g)"),
                "carbs": num("New daily carb goal (g)"),
                "fat": num("New daily fat goal (g)"),
            ]),
            isWrite: true
        ),
        ChatToolSpec(
            name: "create_calculator",
            description: "Create a nutrition calculator (build-your-own-meal template with ingredients and portion options, e.g. parsed from a restaurant's nutrition PDF). The user reviews and can edit everything before saving.",
            parameters: obj([
                "name": str("Calculator name, usually the restaurant/brand, e.g. \"Wegmans Subs\""),
                "brand": str("Optional brand note"),
                "ingredients": arr("Ingredients with portion options", items: ingredientSchema),
            ], required: ["name", "ingredients"]),
            isWrite: true
        ),
        ChatToolSpec(
            name: "update_calculator",
            description: "Update an existing nutrition calculator. Provide the full new ingredient list when changing ingredients — it replaces the old list. The user reviews before saving.",
            parameters: obj([
                "calculator_id": str("Calculator UUID"),
                "name": str("New name"),
                "brand": str("New brand note"),
                "ingredients": arr("Full replacement ingredient list", items: ingredientSchema),
            ], required: ["calculator_id"]),
            isWrite: true
        ),
    ]

    static func spec(named name: String) -> ChatToolSpec? {
        all.first { $0.name == name }
    }

    static let readOnlyBundle: [ChatToolSpec] = all.filter { !$0.isWrite }
    static let journalWriteBundle: [ChatToolSpec] = all.filter {
        [
            "log_entry", "update_entry", "delete_entry", "save_food",
            "log_saved_food", "update_food", "update_goals",
        ].contains($0.name)
    }
    static let calculatorWriteBundle: [ChatToolSpec] = all.filter {
        ["create_calculator", "update_calculator"].contains($0.name)
    }

    // MARK: Provider Encodings

    /// Gemini's Schema proto wants uppercase type names ("OBJECT", "STRING").
    /// Walks a lowercase JSON schema and uppercases every "type" value.
    static func geminiSchema(_ schema: JSONValue) -> JSONValue {
        switch schema {
        case .object(let dict):
            var result: [String: JSONValue] = [:]
            for (key, value) in dict {
                if key == "type", case .string(let type) = value {
                    result[key] = .string(type.uppercased())
                } else {
                    result[key] = geminiSchema(value)
                }
            }
            return .object(result)
        case .array(let items):
            return .array(items.map { geminiSchema($0) })
        default:
            return schema
        }
    }

    // MARK: Activity Chip Summaries

    /// Human-readable label for a tool call, shown on the transcript chip.
    static func summary(for name: String, args: JSONValue) -> String {
        switch name {
        case "get_daily_summary":
            return "Read journal: \(args["date"]?.stringValue ?? "today")"
        case "query_entries":
            let start = args["start_date"]?.stringValue ?? "?"
            let end = args["end_date"]?.stringValue ?? "?"
            return "Read journal: \(start) – \(end)"
        case "search_food_bank":
            return "Searched Food Bank: “\(args["query"]?.stringValue ?? "")”"
        case "get_goals":
            return "Read goals"
        case "get_active_energy":
            return "Read Apple Health energy: \(args["date"]?.stringValue ?? "today")"
        case "list_calculators":
            return "Listed calculators"
        case "get_calculator":
            return "Read calculator"
        case "web_search":
            return "Searched the web: “\(args["query"]?.stringValue ?? "")”"
        case "fetch_url":
            let url = args["url"]?.stringValue ?? ""
            let host = URL(string: url)?.host ?? url
            return "Fetched \(host)"
        case "read_conversation_source":
            return "Read conversation source"
        case "get_nutrition_context":
            return "Read nutrition context: \(args["date"]?.stringValue ?? "today")"
        case "log_entry":
            return "Logged: \(args["name"]?.stringValue ?? "food")"
        case "update_entry":
            return "Updated journal entry"
        case "delete_entry":
            return "Deleted journal entry"
        case "save_food":
            return "Saved to Food Bank: \(args["name"]?.stringValue ?? "food")"
        case "log_saved_food":
            return "Logged saved food"
        case "update_food":
            return "Updated Food Bank item"
        case "update_goals":
            return "Updated goals"
        case "create_calculator":
            return "Created calculator: \(args["name"]?.stringValue ?? "")"
        case "update_calculator":
            return "Updated calculator"
        default:
            return name
        }
    }

    /// SF Symbol for the activity chip.
    static func icon(for name: String) -> String {
        switch name {
        case "get_daily_summary", "query_entries", "get_nutrition_context": "book.pages"
        case "search_food_bank", "list_calculators", "get_calculator": "refrigerator"
        case "get_goals", "update_goals": "target"
        case "get_active_energy": "flame"
        case "web_search": "globe"
        case "fetch_url": "arrow.down.doc"
        case "read_conversation_source": "doc.text.magnifyingglass"
        case "log_entry", "update_entry", "log_saved_food": "square.and.pencil"
        case "delete_entry": "trash"
        case "save_food", "update_food": "tray.and.arrow.down"
        case "create_calculator", "update_calculator": "plusminus.circle"
        default: "wrench"
        }
    }
}
