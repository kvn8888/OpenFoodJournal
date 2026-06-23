// Macros — Food Journaling App
// AGPL-3.0 License

import Foundation
import HealthKit
import Observation
import SwiftData

@Observable
@MainActor
final class HealthKitService {
    var isAuthorized = false
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    @ObservationIgnored
    private let tursoMirror: TursoMirrorService?

    init(tursoMirror: TursoMirrorService? = nil) {
        self.tursoMirror = tursoMirror
    }

    enum SyncResult {
        case synced
        case skipped
        case failed(String)
    }

    struct SyncSummary {
        var synced = 0
        var skipped = 0
        var failed = 0

        var message: String {
            "\(synced) synced, \(skipped) already current, \(failed) failed."
        }
    }

    private struct SampleDefinition {
        let key: String
        let quantityTypeIdentifier: HKQuantityTypeIdentifier
        let unit: HKUnit
        let value: (NutritionEntry) -> Double?
    }

    private static let sampleDefinitions: [SampleDefinition] = [
        SampleDefinition(key: "dietaryEnergyConsumed", quantityTypeIdentifier: .dietaryEnergyConsumed, unit: .kilocalorie()) { $0.calories },
        SampleDefinition(key: "dietaryProtein", quantityTypeIdentifier: .dietaryProtein, unit: .gram()) { $0.protein },
        SampleDefinition(key: "dietaryCarbohydrates", quantityTypeIdentifier: .dietaryCarbohydrates, unit: .gram()) { $0.carbs },
        SampleDefinition(key: "dietaryFatTotal", quantityTypeIdentifier: .dietaryFatTotal, unit: .gram()) { $0.fat },
        SampleDefinition(key: "dietaryFiber", quantityTypeIdentifier: .dietaryFiber, unit: .gram()) { micronutrientValue($0, id: "fiber") },
        SampleDefinition(key: "dietarySugar", quantityTypeIdentifier: .dietarySugar, unit: .gram()) { micronutrientValue($0, id: "sugar", aliases: ["Sugar", "Total Sugar", "Total Sugars"]) },
        SampleDefinition(key: "dietarySodium", quantityTypeIdentifier: .dietarySodium, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "sodium") },
        SampleDefinition(key: "dietaryCholesterol", quantityTypeIdentifier: .dietaryCholesterol, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "cholesterol") },
        SampleDefinition(key: "dietaryFatSaturated", quantityTypeIdentifier: .dietaryFatSaturated, unit: .gram()) { micronutrientValue($0, id: "saturated_fat") },
        SampleDefinition(key: "dietaryVitaminA", quantityTypeIdentifier: .dietaryVitaminA, unit: .gramUnit(with: .micro)) { micronutrientValue($0, id: "vitamin_a") },
        SampleDefinition(key: "dietaryVitaminC", quantityTypeIdentifier: .dietaryVitaminC, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "vitamin_c") },
        SampleDefinition(key: "dietaryCalcium", quantityTypeIdentifier: .dietaryCalcium, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "calcium") },
        SampleDefinition(key: "dietaryIron", quantityTypeIdentifier: .dietaryIron, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "iron") },
        SampleDefinition(key: "dietaryPotassium", quantityTypeIdentifier: .dietaryPotassium, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "potassium") },
    ]

    private static func micronutrientValue(
        _ entry: NutritionEntry,
        id: String,
        aliases: [String] = []
    ) -> Double? {
        KnownMicronutrients.value(in: entry.micronutrients, forID: id, aliases: aliases)?.value
    }

    @ObservationIgnored
    private let store = HKHealthStore()

    @ObservationIgnored
    private let writeTypes: Set<HKSampleType> = {
        var types: Set<HKSampleType> = []
        let ids = sampleDefinitions.map(\.quantityTypeIdentifier)
        for id in ids {
            if let type = HKQuantityType.quantityType(forIdentifier: id) {
                types.insert(type)
            }
        }
        return types
    }()

    @ObservationIgnored
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
        _ = await sync(entry, force: true)
    }

    @discardableResult
    func sync(_ entry: NutritionEntry, in modelContext: ModelContext? = nil, force: Bool = false) async -> SyncResult {
        guard isAvailable, isAuthorized else { return .skipped }

        let writeHash = entry.healthKitWriteHash
        if !force,
           entry.healthKitSyncStatus == HealthKitSyncStatus.synced,
           entry.healthKitLastWriteHash == writeHash {
            return .skipped
        }

        let nextVersion = entry.healthKitSyncVersion + 1
        let samples = makeSamples(for: entry, syncVersion: nextVersion)

        do {
            try await deleteExistingSamples(for: entry)
            if !samples.isEmpty {
                try await store.save(samples)
            }

            entry.healthKitSyncStatus = HealthKitSyncStatus.synced
            entry.healthKitSyncedAt = .now
            entry.healthKitSyncVersion = nextVersion
            entry.healthKitLastWriteHash = writeHash
            entry.healthKitLastError = nil
            try? modelContext?.save()
            tursoMirror?.scheduleMirror(reason: "healthkit_sync")
            return .synced
        } catch {
            entry.healthKitSyncStatus = HealthKitSyncStatus.failed
            entry.healthKitLastError = error.localizedDescription
            try? modelContext?.save()
            tursoMirror?.scheduleMirror(reason: "healthkit_sync_failed")
            #if DEBUG
            print("[HealthKitService] Sync failed: \(error)")
            #endif
            return .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func deleteSamples(for entry: NutritionEntry) async -> SyncResult {
        guard isAvailable, isAuthorized else { return .skipped }

        do {
            try await deleteExistingSamples(for: entry)
            return .synced
        } catch {
            #if DEBUG
            print("[HealthKitService] Delete failed: \(error)")
            #endif
            return .failed(error.localizedDescription)
        }
    }

    func syncMissingEntries(
        _ entries: [NutritionEntry],
        in modelContext: ModelContext,
        force: Bool = false
    ) async -> SyncSummary {
        var summary = SyncSummary()

        for entry in entries {
            let result = await sync(entry, in: modelContext, force: force)
            switch result {
            case .synced:
                summary.synced += 1
            case .skipped:
                summary.skipped += 1
            case .failed:
                summary.failed += 1
            }
        }

        try? modelContext.save()
        tursoMirror?.scheduleMirror(reason: "healthkit_backfill")
        return summary
    }

    private func makeSamples(for entry: NutritionEntry, syncVersion: Int) -> [HKQuantitySample] {
        let metadata: [String: Any] = [
            HKMetadataKeyFoodType: entry.name,
            "OpenFoodJournalEntryID": entry.id.uuidString
        ]

        var samples: [HKQuantitySample] = []

        for definition in Self.sampleDefinitions {
            guard let value = definition.value(entry),
                  value.isFinite,
                  value > 0,
                  let type = HKQuantityType.quantityType(forIdentifier: definition.quantityTypeIdentifier)
            else { continue }

            var sampleMetadata = metadata
            sampleMetadata[HKMetadataKeySyncIdentifier] = syncIdentifier(for: entry.id, sampleKey: definition.key)
            sampleMetadata[HKMetadataKeySyncVersion] = syncVersion
            sampleMetadata["OpenFoodJournalNutrient"] = definition.key

            let quantity = HKQuantity(unit: definition.unit, doubleValue: value)
            let sample = HKQuantitySample(
                type: type,
                quantity: quantity,
                start: entry.healthKitSampleTimestamp,
                end: entry.healthKitSampleTimestamp,
                metadata: sampleMetadata
            )
            samples.append(sample)
        }

        return samples
    }

    private func deleteExistingSamples(for entry: NutritionEntry) async throws {
        for definition in Self.sampleDefinitions {
            guard let type = HKQuantityType.quantityType(forIdentifier: definition.quantityTypeIdentifier) else { continue }
            let samples = try await samples(
                type: type,
                syncIdentifier: syncIdentifier(for: entry.id, sampleKey: definition.key)
            )
            if !samples.isEmpty {
                try await store.delete(samples)
            }
        }
    }

    private func samples(type: HKSampleType, syncIdentifier: String) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForObjects(
                withMetadataKey: HKMetadataKeySyncIdentifier,
                operatorType: .equalTo,
                value: syncIdentifier
            )
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }

    private func syncIdentifier(for entryID: UUID, sampleKey: String) -> String {
        "k3vnc.OpenFoodJournal.\(entryID.uuidString).\(sampleKey)"
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
