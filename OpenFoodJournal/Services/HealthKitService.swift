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

        if let fiber = entry.fiber { addSample(.dietaryFiber, value: fiber, unit: .gram()) }
        if let sugar = entry.sugar { addSample(.dietarySugar, value: sugar, unit: .gram()) }
        if let sodium = entry.sodium { addSample(.dietarySodium, value: sodium, unit: .gramUnit(with: .milli)) }
        if let cholesterol = entry.cholesterol { addSample(.dietaryCholesterol, value: cholesterol, unit: .gramUnit(with: .milli)) }

        do {
            try await store.save(samples)
        } catch {
            // Non-fatal — HealthKit write failure doesn't block core app function
            print("[HealthKitService] Write failed: \(error)")
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
