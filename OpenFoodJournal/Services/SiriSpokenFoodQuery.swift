// AGPL-3.0 License

import Foundation

struct SiriSpokenFoodQuery {
    var name: String
    var quantity: Double?
    var unit: String?
    var meal: MealType?
    var dayOffset: Int?

    init(name: String) {
        self.name = name
    }

    init(_ text: String) {
        self.init(name: "")
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let verb = remaining.prefixMatch(of: #/(?i)(?:log|add|track)\s+/#) {
            remaining.removeSubrange(verb.range)
        }
        // Match phrases with the day before or after the meal.
        removeDay(from: &remaining)
        if let match = remaining.firstMatch(of: #/(?i)\s+for\s+(breakfast|lunch|dinner|(?:a\s+)?snack)$/#) {
            meal = MealType(rawValue: match.1.lowercased().hasSuffix("snack") ? "Snack" : match.1.capitalized)
            remaining.removeSubrange(match.range)
        }
        if dayOffset == nil { removeDay(from: &remaining) }

        if let amount = remaining.prefixMatch(of: #/([+-]?(?:[0-9]+(?:[.,][0-9]+)?|\.[0-9]+))(?=\s|\p{L}|$)/#) {
            quantity = Double(amount.1.replacingOccurrences(of: ",", with: "."))
            remaining = String(remaining[amount.range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let portion = remaining.prefixMatch(of: #/(?i)([\p{L}][\p{L}\s-]*?)\s+of\s+/#) {
                unit = SiriFoodUnits.normalized(String(portion.1))
                remaining.removeSubrange(portion.range)
            } else if let spokenUnit = SiriFoodUnits.spokenPrefix(in: remaining) {
                unit = spokenUnit.unit
                remaining = spokenUnit.remainder
            }
        }
        name = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private mutating func removeDay(from text: inout String) {
        guard let match = text.firstMatch(of: #/(?i)\s+(today|yesterday)$/#) else { return }
        dayOffset = match.1.lowercased() == "today" ? 0 : -1
        text.removeSubrange(match.range)
    }
}

enum SiriFoodUnits {
    private static let aliases: [String: String] = [
        "g": "g", "gram": "g", "grams": "g",
        "oz": "oz", "ounce": "oz", "ounces": "oz",
        "lb": "lb", "lbs": "lb", "pound": "lb", "pounds": "lb",
        "kg": "kg", "kilogram": "kg", "kilograms": "kg",
        "ml": "mL", "milliliter": "mL", "milliliters": "mL", "millilitre": "mL", "millilitres": "mL",
        "l": "L", "liter": "L", "liters": "L", "litre": "L", "litres": "L",
        "cup": "cup", "cups": "cup",
        "tbsp": "tbsp", "tablespoon": "tbsp", "tablespoons": "tbsp",
        "tsp": "tsp", "teaspoon": "tsp", "teaspoons": "tsp",
        "fl oz": "fl oz", "fluid ounce": "fl oz", "fluid ounces": "fl oz",
        "serving": "serving", "servings": "serving",
        "slice": "slice", "slices": "slice",
        "piece": "piece", "pieces": "piece",
        "scoop": "scoop", "scoops": "scoop"
    ]

    static func normalized(_ unit: String) -> String {
        let cleaned = unit.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return aliases[cleaned] ?? cleaned
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = normalized(lhs)
        let rhs = normalized(rhs)
        return lhs == rhs || lhs == plural(of: rhs) || rhs == plural(of: lhs)
    }

    private static func plural(of unit: String) -> String {
        if unit.hasSuffix("y"), let beforeY = unit.dropLast().last, !"aeiou".contains(beforeY) {
            return unit.dropLast() + "ies"
        }
        if ["ch", "sh", "s", "x", "z"].contains(where: { unit.hasSuffix($0) }) {
            return unit + "es"
        }
        return unit + "s"
    }

    static func spokenPrefix(in text: String) -> (unit: String, remainder: String)? {
        let words = text.split(whereSeparator: \.isWhitespace)
        for count in [2, 1] where words.count > count {
            let candidate = words.prefix(count).joined(separator: " ").lowercased()
            if let unit = aliases[candidate] {
                return (unit, words.dropFirst(count).joined(separator: " "))
            }
        }
        return nil
    }
}
