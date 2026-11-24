// AGPL-3.0 License

import Foundation

struct SiriSpokenFoodQuery {
    var name: String
    var quantity: Double?
    var unit: String?
    var meal: MealType?
    var dayOffset: Int?
    var foodBankOnly = false

    private static let spokenQuantities: [String: Double] = [
        "a": 1, "an": 1, "half": 0.5, "quarter": 0.25,
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12
    ]

    init(name: String) {
        self.name = name
    }

    init(_ text: String) {
        self.init(name: "")
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let punctuation = remaining.firstMatch(of: #/[.!?]+$/#) {
            remaining.removeSubrange(punctuation.range)
        }
        if let verb = remaining.prefixMatch(of: #/(?i)(?:log|add|track|i\s+(?:ate|had|drank|drink))\s+/#) {
            remaining.removeSubrange(verb.range)
        }
        // Match phrases with the day before or after the meal.
        removeDay(from: &remaining)
        removeFoodBankSource(from: &remaining)
        if let match = remaining.firstMatch(of: #/(?i)\s+for\s+(breakfast|lunch|dinner|(?:a\s+)?snack)$/#) {
            meal = MealType(rawValue: match.1.lowercased().hasSuffix("snack") ? "Snack" : match.1.capitalized)
            remaining.removeSubrange(match.range)
        }
        if dayOffset == nil { removeDay(from: &remaining) }
        if !foodBankOnly { removeFoodBankSource(from: &remaining) }

        if let amount = remaining.prefixMatch(of: #/([+-]?(?:[0-9]+(?:[.,][0-9]+)?|\.[0-9]+))(?=\s|\p{L}|$)/#) {
            quantity = Double(amount.1.replacingOccurrences(of: ",", with: "."))
            remaining = String(remaining[amount.range.upperBound...]).trimmingCharacters(in: .whitespaces)
            unit = Self.removeUnit(from: &remaining)
        } else if let amount = remaining.prefixMatch(of: #/(\p{L}+)\s+/#),
                  let spokenQuantity = Self.spokenQuantities[amount.1.lowercased()] {
            var food = String(remaining[amount.range.upperBound...])
            if spokenQuantity < 1, let article = food.prefixMatch(of: #/(?i)an?\s+/#) {
                food.removeSubrange(article.range)
            }
            let spokenUnit = Self.removeUnit(from: &food, allowsCustomUnit: false)
            // Keep leading number words in food names such as One Degree Oats.
            if spokenUnit != nil {
                quantity = spokenQuantity
                unit = spokenUnit
                remaining = food
            }
        }
        name = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeUnit(from text: inout String, allowsCustomUnit: Bool = true) -> String? {
        if let portion = text.prefixMatch(of: #/(?i)([\p{L}][\p{L}\s-]*?)\s+of\s+/#),
           allowsCustomUnit || SiriFoodUnits.isKnown(String(portion.1)) {
            text.removeSubrange(portion.range)
            return SiriFoodUnits.normalized(String(portion.1))
        }
        if let spokenUnit = SiriFoodUnits.spokenPrefix(in: text) {
            text = spokenUnit.remainder
            return spokenUnit.unit
        }
        return nil
    }

    private mutating func removeDay(from text: inout String) {
        guard let match = text.firstMatch(of: #/(?i)\s+(today|yesterday)$/#) else { return }
        dayOffset = match.1.lowercased() == "today" ? 0 : -1
        text.removeSubrange(match.range)
    }

    private mutating func removeFoodBankSource(from text: inout String) {
        guard let match = text.firstMatch(of: #/(?i)\s+(?:from|in)\s+(?:my|the)\s+(?:food bank|saved foods?(?: list)?)$/#) else { return }
        foodBankOnly = true
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
        "pie": "pie", "pies": "pie",
        "scoop": "scoop", "scoops": "scoop"
    ]

    static func normalized(_ unit: String) -> String {
        let cleaned = unit.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return aliases[cleaned] ?? cleaned
    }

    static func isKnown(_ unit: String) -> Bool {
        let key = unit.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return aliases[key] != nil
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
