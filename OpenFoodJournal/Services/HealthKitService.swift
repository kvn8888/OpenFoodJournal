// Macros — Food Journaling App
// AGPL-3.0 License

import Foundation
import HealthKit
import Observation

@Observable
@MainActor
final class HealthKitService {
    var isAuthorized = false
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let store = HKHealthStore()

    private let writeTypes: Set<HKSampleType> = {
        var types: Set<HKSampleType> = []
        let ids: [HKQuantityTypeIdentifier] = [
            .dietaryEnergyConsumed,
            .dietaryProtein,
            .dietaryCarbohydrates,
            .dietaryFatTotal,
            .dietaryFiber,
            .dietarySugar,
            .dietarySodium,
            .dietaryCholesterol,
        ]
        for id in ids {
            if let type = HKQuantityType.quantityType(forIdentifier: id) {
                types.insert(type)
            }
        }
        return types
    }()

    private let readTypes: Set<HKObjectType> = {
        var types: Set<HKObjectType> = []
        if let active = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            types.insert(active)
        }
        return types
    }()

    // MARK: - Authorization

    func requestAuthorization() async {
        guard isAvailable else { return }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
            isAuthorized = true
        } catch {
            isAuthorized = false
        }
    }

    // MARK: - Write Nutrition

    func write(_ entry: NutritionEntry) async {
        guard isAvailable, isAuthorized else { return }

        let metadata: [String: Any] = [
            HKMetadataKeyFoodType: entry.name
        ]

        var samples: [HKQuantitySample] = []

        func addSample(_ id: HKQuantityTypeIdentifier, value: Double, unit: HKUnit) {
            guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return }
            let quantity = HKQuantity(unit: unit, doubleValue: value)
            let sample = HKQuantitySample(type: type, quantity: quantity, start: entry.timestamp, end: entry.timestamp, metadata: metadata)
            samples.append(sample)
        }

        addSample(.dietaryEnergyConsumed, value: entry.calories, unit: .kilocalorie())
        addSample(.dietaryProtein, value: entry.protein, unit: .gram())
        addSample(.dietaryCarbohydrates, value: entry.carbs, unit: .gram())
        addSample(.dietaryFatTotal, value: entry.fat, unit: .gram())

        // Map known micronutrient names to HealthKit identifiers.
        // Only nutrients with a known HK mapping get written; the rest are stored
        // in SwiftData only. This mapping grows as we add more HealthKit support.
        let hkMicroMap: [String: (id: HKQuantityTypeIdentifier, unit: HKUnit)] = [
            "Fiber":         (.dietaryFiber,       .gram()),
            "Sugar":         (.dietarySugar,       .gram()),
            "Sodium":        (.dietarySodium,      .gramUnit(with: .milli)),
            "Cholesterol":   (.dietaryCholesterol, .gramUnit(with: .milli)),
            "Saturated Fat": (.dietaryFatSaturated, .gram()),
            "Vitamin A":     (.dietaryVitaminA,    .gramUnit(with: .micro)),
            "Vitamin C":     (.dietaryVitaminC,    .gramUnit(with: .milli)),
            "Calcium":       (.dietaryCalcium,     .gramUnit(with: .milli)),
            "Iron":          (.dietaryIron,        .gramUnit(with: .milli)),
            "Potassium":     (.dietaryPotassium,   .gramUnit(with: .milli)),
        ]

        for (name, micro) in entry.micronutrients {
            if let mapping = hkMicroMap[name] {
                addSample(mapping.id, value: micro.value, unit: mapping.unit)
            }
        }

        do {
            try await store.save(samples)
        } catch {
            // Non-fatal — HealthKit write failure doesn't block core app function
            #if DEBUG
            print("[HealthKitService] Write failed: \(error)")
            #endif
        }
    }

    // MARK: - Read Active Energy

    func fetchActiveEnergy(for date: Date) async -> Double {
        guard isAvailable, isAuthorized,
              let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)
        else { return 0 }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return 0 }

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                let value = result?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }
}
