// OpenFoodJournal — deterministic Shelf recommendation scoring.
// Local, explainable, and intentionally independent from SwiftUI/SwiftData.

import Foundation

struct ShelfNutrition: Equatable, Sendable {
    var calories: Double = 0
    var protein: Double = 0
    var fiber: Double?
    var carbs: Double = 0
    var fat: Double = 0
    var sodium: Double?

    func value(for nutrient: ShelfNutrient) -> Double? {
        switch nutrient {
        case .calories: calories
        case .protein: protein
        case .fiber: fiber
        case .carbs: carbs
        case .fat: fat
        case .sodium: sodium
        }
    }

    func adding(_ other: ShelfNutrition, scaledBy multiplier: Double) -> ShelfNutrition {
        ShelfNutrition(
            calories: calories + other.calories * multiplier,
            protein: protein + other.protein * multiplier,
            fiber: Self.addOptional(fiber, other.fiber, multiplier: multiplier),
            carbs: carbs + other.carbs * multiplier,
            fat: fat + other.fat * multiplier,
            sodium: Self.addOptional(sodium, other.sodium, multiplier: multiplier)
        )
    }

    private static func addOptional(_ lhs: Double?, _ rhs: Double?, multiplier: Double) -> Double? {
        guard let rhs else { return lhs }
        return (lhs ?? 0) + rhs * multiplier
    }
}

struct ShelfNutritionGoals: Equatable, Sendable {
    var calories: Double
    var protein: Double
    var fiber: Double = KnownMicronutrients.fiber.dailyValue
    var carbs: Double
    var fat: Double
    var sodium: Double = KnownMicronutrients.sodium.dailyValue

    func value(for nutrient: ShelfNutrient) -> Double {
        switch nutrient {
        case .calories: calories
        case .protein: protein
        case .fiber: fiber
        case .carbs: carbs
        case .fat: fat
        case .sodium: sodium
        }
    }

    func replacingCalories(with calories: Double) -> ShelfNutritionGoals {
        ShelfNutritionGoals(
            calories: calories,
            protein: protein,
            fiber: fiber,
            carbs: carbs,
            fat: fat,
            sodium: sodium
        )
    }
}

struct ShelfFoodCandidate: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let baseQuantity: Double
    let baseUnit: String
    let nutrition: ShelfNutrition
    let isOnShelf: Bool
    let isManuallyArchived: Bool

    var hasIncompleteNutrition: Bool {
        nutrition.fiber == nil || nutrition.sodium == nil
    }
}

struct ShelfRollingWeekContext: Equatable, Sendable {
    /// The six calendar days before the day being scored. A nil value means
    /// that day does not have enough logging evidence to count as coverage.
    var priorDayCalories: [Double?] = []

    static let none = ShelfRollingWeekContext()
}

struct ShelfEffectiveCalorieTarget: Equatable, Sendable {
    let calories: Double
    let adjustment: Double
    let usedRollingWeek: Bool
    let coveredPriorDays: Int
}

struct ShelfRecommendationConfiguration: Equatable, Sendable {
    var enabled: Bool = true
    var suggestionCount: Int = 3
    var energyIntent: ShelfEnergyIntent = .maintain
    var nutritionEmphasis: ShelfNutritionEmphasis = .balanced
    var triggerFraction: Double = 0.5
    var incompleteNutritionPolicy: ShelfIncompleteNutritionPolicy = .includeCautiously
    var useRollingWeekContext: Bool = true
    var hardCaps: Set<ShelfNutrient> = []
    var customPolicies: [ShelfNutrient: ShelfNutrientPolicy] = [
        .calories: .stayNear,
        .protein: .reach,
        .fiber: .reach,
        .carbs: .ignore,
        .fat: .ignore,
        .sodium: .tryToAvoid
    ]
    var customStrengths: [ShelfNutrient: ShelfPolicyStrength] = Dictionary(
        uniqueKeysWithValues: ShelfNutrient.allCases.map { ($0, .standard) }
    )

    var clampedSuggestionCount: Int { min(max(suggestionCount, 1), 5) }
    var clampedTriggerFraction: Double { min(max(triggerFraction, 0), 1) }
}

struct ShelfRecommendation: Identifiable, Equatable, Sendable {
    let foodID: UUID
    let foodName: String
    let quantity: Double
    let unit: String
    let servingMultiplier: Double
    let score: Double
    let reason: String
    let hasIncompleteNutrition: Bool

    var id: UUID { foodID }

    var quantityText: String {
        quantity.formatted(.number.precision(.fractionLength(0...2)))
    }
}

enum ShelfRecommendationEngine {
    static let servingMultipliers: [Double] = [0.5, 1, 1.5, 2]
    static let minimumCoveredPriorDays = 5

    static func shouldShow(
        currentCalories: Double,
        calorieGoal: Double,
        configuration: ShelfRecommendationConfiguration
    ) -> Bool {
        guard configuration.enabled, calorieGoal > 0 else { return false }
        // Triggering deliberately uses only the selected day. Rolling context
        // changes ranking pace, never when the Shelf appears.
        return currentCalories >= calorieGoal * configuration.clampedTriggerFraction
    }

    static func effectiveCalorieTarget(
        dailyGoal: Double,
        context: ShelfRollingWeekContext,
        configuration: ShelfRecommendationConfiguration
    ) -> ShelfEffectiveCalorieTarget {
        guard configuration.useRollingWeekContext, dailyGoal > 0 else {
            return ShelfEffectiveCalorieTarget(
                calories: dailyGoal,
                adjustment: 0,
                usedRollingWeek: false,
                coveredPriorDays: 0
            )
        }

        let priorSix = Array(context.priorDayCalories.suffix(6))
        let covered = priorSix.compactMap { value -> Double? in
            guard let value, value > 0 else { return nil }
            return value
        }
        guard priorSix.count == 6, covered.count >= minimumCoveredPriorDays else {
            return ShelfEffectiveCalorieTarget(
                calories: dailyGoal,
                adjustment: 0,
                usedRollingWeek: false,
                coveredPriorDays: covered.count
            )
        }

        // Estimate one missing day from covered-day pace rather than treating
        // it as zero. The clamp prevents incomplete logs from manufacturing a
        // huge false calorie budget.
        let average = covered.reduce(0, +) / Double(covered.count)
        let estimatedPriorTotal = average * 6
        let rawTodayTarget = dailyGoal * 7 - estimatedPriorTotal
        let maximumAdjustment = min(300, dailyGoal * 0.15)
        let adjustment = min(max(rawTodayTarget - dailyGoal, -maximumAdjustment), maximumAdjustment)
        return ShelfEffectiveCalorieTarget(
            calories: max(1, dailyGoal + adjustment),
            adjustment: adjustment,
            usedRollingWeek: true,
            coveredPriorDays: covered.count
        )
    }

    static func recommend(
        foods: [ShelfFoodCandidate],
        current: ShelfNutrition,
        goals: ShelfNutritionGoals,
        configuration: ShelfRecommendationConfiguration,
        rollingWeekContext: ShelfRollingWeekContext = .none
    ) -> [ShelfRecommendation] {
        guard shouldShow(
            currentCalories: current.calories,
            calorieGoal: goals.calories,
            configuration: configuration
        ) else { return [] }

        let eligible = foods.filter {
            $0.isOnShelf && !$0.isManuallyArchived && $0.nutrition.calories > 0
        }
        guard !eligible.isEmpty else { return [] }

        let knownSodium = eligible.compactMap(\.nutrition.sodium).filter { $0 >= 0 }.sorted()
        let sodiumEstimate = percentile75(knownSodium) ?? max(goals.sodium * 0.15, 0)
        let calorieTarget = effectiveCalorieTarget(
            dailyGoal: goals.calories,
            context: rollingWeekContext,
            configuration: configuration
        )
        let scoringGoals = goals.replacingCalories(with: calorieTarget.calories)
        let directives = policyDirectives(for: configuration)

        let bestPerFood = eligible.compactMap { food -> ShelfRecommendation? in
            if configuration.incompleteNutritionPolicy == .exclude,
               food.hasIncompleteNutrition {
                return nil
            }

            let sodiumWasEstimated = food.nutrition.sodium == nil
            var estimatedNutrition = food.nutrition
            if sodiumWasEstimated { estimatedNutrition.sodium = sodiumEstimate }

            return servingMultipliers.compactMap { multiplier in
                score(
                    food: food,
                    nutrition: estimatedNutrition,
                    multiplier: multiplier,
                    current: current,
                    goals: scoringGoals,
                    hardCapGoals: goals,
                    directives: directives,
                    configuration: configuration,
                    calorieTarget: calorieTarget,
                    sodiumWasEstimated: sodiumWasEstimated
                )
            }
            .sorted(by: recommendationSort)
            .first
        }

        // A soft policy may make every option a tradeoff. Keep ranking those
        // foods instead of turning a preference into an accidental hard ban.
        return bestPerFood
            .sorted(by: recommendationSort)
            .prefix(configuration.clampedSuggestionCount)
            .map { $0 }
    }

    private struct PolicyDirective: Sendable {
        let policy: ShelfNutrientPolicy
        let strength: ShelfPolicyStrength
    }

    private static func policyDirectives(
        for configuration: ShelfRecommendationConfiguration
    ) -> [ShelfNutrient: PolicyDirective] {
        var directives = nutritionDirectives(for: configuration)
        directives[.calories] = energyDirective(for: configuration)
        return directives
    }

    private static func energyDirective(
        for configuration: ShelfRecommendationConfiguration
    ) -> PolicyDirective {
        switch configuration.energyIntent {
        case .cut:
            PolicyDirective(policy: .tryToAvoid, strength: .strong)
        case .maintain:
            PolicyDirective(policy: .stayNear, strength: .standard)
        case .bulk:
            PolicyDirective(policy: .reach, strength: .strong)
        case .custom:
            PolicyDirective(
                policy: configuration.customPolicies[.calories] ?? .stayNear,
                strength: configuration.customStrengths[.calories] ?? .standard
            )
        }
    }

    private static func nutritionDirectives(
        for configuration: ShelfRecommendationConfiguration
    ) -> [ShelfNutrient: PolicyDirective] {
        func directive(_ policy: ShelfNutrientPolicy, _ strength: ShelfPolicyStrength) -> PolicyDirective {
            PolicyDirective(policy: policy, strength: strength)
        }

        switch configuration.nutritionEmphasis {
        case .balanced:
            return [
                .protein: directive(.reach, .standard),
                .fiber: directive(.reach, .standard),
                .carbs: directive(.stayNear, .gentle),
                .fat: directive(.stayNear, .gentle),
                .sodium: directive(.tryToAvoid, .standard)
            ]
        case .proteinFocus:
            return [
                .protein: directive(.reach, .strong),
                .fiber: directive(.reach, .gentle),
                .carbs: directive(.ignore, .gentle),
                .fat: directive(.ignore, .gentle),
                .sodium: directive(.tryToAvoid, .standard)
            ]
        case .fiberFocus:
            return [
                .protein: directive(.reach, .gentle),
                .fiber: directive(.reach, .strong),
                .carbs: directive(.ignore, .gentle),
                .fat: directive(.ignore, .gentle),
                .sodium: directive(.tryToAvoid, .standard)
            ]
        case .lowSodium:
            return [
                .protein: directive(.reach, .standard),
                .fiber: directive(.reach, .standard),
                .carbs: directive(.ignore, .gentle),
                .fat: directive(.ignore, .gentle),
                .sodium: directive(.tryToAvoid, .strong)
            ]
        case .custom:
            return Dictionary(uniqueKeysWithValues: ShelfNutrient.nutritionCases.map { nutrient in
                (
                    nutrient,
                    PolicyDirective(
                        policy: configuration.customPolicies[nutrient] ?? .ignore,
                        strength: configuration.customStrengths[nutrient] ?? .standard
                    )
                )
            })
        }
    }

    private static func score(
        food: ShelfFoodCandidate,
        nutrition: ShelfNutrition,
        multiplier: Double,
        current: ShelfNutrition,
        goals: ShelfNutritionGoals,
        hardCapGoals: ShelfNutritionGoals,
        directives: [ShelfNutrient: PolicyDirective],
        configuration: ShelfRecommendationConfiguration,
        calorieTarget: ShelfEffectiveCalorieTarget,
        sodiumWasEstimated: Bool
    ) -> ShelfRecommendation? {
        let after = current.adding(nutrition, scaledBy: multiplier)
        guard !violatesHardCap(
            current: current,
            after: after,
            goals: hardCapGoals,
            hardCaps: configuration.hardCaps
        ) else { return nil }

        var score = -0.08 * pow(abs(multiplier - 1), 1.25)
        var improvements: [(nutrient: ShelfNutrient, amount: Double)] = []

        for nutrient in ShelfNutrient.allCases {
            guard let directive = directives[nutrient], directive.policy != .ignore,
                  let beforeValue = current.value(for: nutrient),
                  let afterValue = after.value(for: nutrient) else { continue }
            let goal = goals.value(for: nutrient)
            guard goal > 0 else { continue }

            let contribution = policyContribution(
                nutrient: nutrient,
                policy: directive.policy,
                strength: directive.strength,
                before: beforeValue,
                after: afterValue,
                goal: goal
            )
            score += contribution
            if contribution > 0.002, directive.policy == .reach || directive.policy == .stayNear {
                improvements.append((nutrient, contribution))
            }
        }

        if sodiumWasEstimated { score -= 0.10 }
        if food.nutrition.fiber == nil { score -= 0.03 }

        return ShelfRecommendation(
            foodID: food.id,
            foodName: food.name,
            quantity: max(food.baseQuantity, 0.01) * multiplier,
            unit: food.baseUnit,
            servingMultiplier: multiplier,
            score: score,
            reason: explanation(
                improvements: improvements,
                after: after,
                goals: goals,
                configuration: configuration,
                calorieTarget: calorieTarget,
                sodiumWasEstimated: sodiumWasEstimated
            ),
            hasIncompleteNutrition: food.hasIncompleteNutrition
        )
    }

    private static func policyContribution(
        nutrient: ShelfNutrient,
        policy: ShelfNutrientPolicy,
        strength: ShelfPolicyStrength,
        before: Double,
        after: Double,
        goal: Double
    ) -> Double {
        let multiplier = strength.multiplier
        switch policy {
        case .reach:
            return 1.25 * multiplier * (
                squaredDeficit(value: before, goal: goal)
                - squaredDeficit(value: after, goal: goal)
            )
        case .stayNear:
            return multiplier * (
                squaredDistance(value: before, goal: goal)
                - squaredDistance(value: after, goal: goal)
            )
        case .tryToAvoid:
            return -multiplier * avoidanceCost(
                nutrient: nutrient,
                before: before,
                after: after,
                goal: goal
            )
        case .ignore:
            return 0
        }
    }

    private static func avoidanceCost(
        nutrient: ShelfNutrient,
        before: Double,
        after: Double,
        goal: Double
    ) -> Double {
        switch nutrient {
        case .sodium:
            return max(0, sodiumPressure(after / goal) - sodiumPressure(before / goal))
        case .calories:
            let addedRatio = max(0, after - before) / goal
            let beforeOvershoot = max(0, before / goal - 1)
            let afterOvershoot = max(0, after / goal - 1)
            return 0.75 * addedRatio
                + 6 * max(0, afterOvershoot * afterOvershoot - beforeOvershoot * beforeOvershoot)
        case .protein, .fiber, .carbs, .fat:
            return max(0, limitPressure(after / goal) - limitPressure(before / goal))
        }
    }

    private static func violatesHardCap(
        current: ShelfNutrition,
        after: ShelfNutrition,
        goals: ShelfNutritionGoals,
        hardCaps: Set<ShelfNutrient>
    ) -> Bool {
        for nutrient in hardCaps {
            guard let beforeValue = current.value(for: nutrient),
                  let afterValue = after.value(for: nutrient) else {
                return true
            }
            let goal = goals.value(for: nutrient)
            guard goal > 0 else { continue }
            if afterValue > goal, afterValue > beforeValue { return true }
        }
        return false
    }

    private static func squaredDeficit(value: Double, goal: Double) -> Double {
        let normalized = max(0, 1 - value / goal)
        return normalized * normalized
    }

    private static func squaredDistance(value: Double, goal: Double) -> Double {
        let normalized = abs(value - goal) / goal
        return normalized * normalized
    }

    static func sodiumPressure(_ ratio: Double) -> Double {
        let ratio = max(ratio, 0)
        if ratio <= 0.8 { return 0.08 * ratio }
        if ratio <= 1 {
            let progress = (ratio - 0.8) / 0.2
            return 0.064 + 0.8 * progress * progress
        }
        let excess = ratio - 1
        return 0.864 + 4 * excess + 6 * excess * excess
    }

    private static func limitPressure(_ ratio: Double) -> Double {
        let ratio = max(ratio, 0)
        if ratio <= 0.8 { return 0.04 * ratio }
        if ratio <= 1 {
            let progress = (ratio - 0.8) / 0.2
            return 0.032 + 0.5 * progress * progress
        }
        let excess = ratio - 1
        return 0.532 + 3 * excess + 5 * excess * excess
    }

    private static func explanation(
        improvements: [(nutrient: ShelfNutrient, amount: Double)],
        after: ShelfNutrition,
        goals: ShelfNutritionGoals,
        configuration: ShelfRecommendationConfiguration,
        calorieTarget: ShelfEffectiveCalorieTarget,
        sodiumWasEstimated: Bool
    ) -> String {
        let top = improvements
            .sorted {
                if $0.amount != $1.amount { return $0.amount > $1.amount }
                return $0.nutrient.rawValue < $1.nutrient.rawValue
            }
            .prefix(2)
            .map { $0.nutrient.label.lowercased() }

        var parts: [String] = []
        if !top.isEmpty { parts.append("Helps " + top.joined(separator: " + ")) }
        if configuration.energyIntent == .cut, !top.contains("calories") {
            parts.append("keeps added calories lighter")
        }
        if calorieTarget.usedRollingWeek, abs(calorieTarget.adjustment) >= 25 {
            let amount = abs(calorieTarget.adjustment).rounded()
            parts.append(calorieTarget.adjustment > 0
                ? "weekly pace allows about \(Int(amount)) more kcal"
                : "weekly pace trims about \(Int(amount)) kcal")
        }
        if sodiumWasEstimated {
            parts.append("sodium unknown")
        } else if let sodium = after.sodium, goals.sodium > 0, sodium > goals.sodium {
            parts.append("watch sodium")
        } else if configuration.hardCaps.contains(.sodium) {
            parts.append("within sodium cap")
        }
        return parts.isEmpty
            ? "Best available fit for today's preferences"
            : parts.prefix(3).joined(separator: "; ")
    }

    private static func percentile75(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let index = Int(ceil(Double(values.count) * 0.75)) - 1
        return values[min(max(index, 0), values.count - 1)]
    }

    nonisolated private static func recommendationSort(
        _ lhs: ShelfRecommendation,
        _ rhs: ShelfRecommendation
    ) -> Bool {
        if abs(lhs.score - rhs.score) > 0.000_000_1 { return lhs.score > rhs.score }
        let nameOrder = lhs.foodName.localizedCaseInsensitiveCompare(rhs.foodName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.foodID.uuidString < rhs.foodID.uuidString
    }
}
