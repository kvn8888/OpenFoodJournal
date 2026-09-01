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

    /// HealthKit has no development/production split — there is exactly one
    /// Health store on the device, shared by every app that can reach it.
    /// A Debug build would appear as a *separate* HKSource writing into the
    /// user's real health data, and sync identifiers only deduplicate within a
    /// source, so overlapping entries would show up twice. Debug builds also
    /// ship entitlements without HealthKit, so this keeps the code path
    /// consistent with what the entitlements already allow.
    var isAvailable: Bool {
        #if DEBUG
        return false
        #else
        return HKHealthStore.isHealthDataAvailable()
        #endif
    }

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
        SampleDefinition(key: "dietaryBiotin", quantityTypeIdentifier: .dietaryBiotin, unit: .gramUnit(with: .micro)) { micronutrientValue($0, id: "biotin") },
        SampleDefinition(key: "dietaryCaffeine", quantityTypeIdentifier: .dietaryCaffeine, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "caffeine") },
        SampleDefinition(key: "dietaryChloride", quantityTypeIdentifier: .dietaryChloride, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "chloride") },
        SampleDefinition(key: "dietaryChromium", quantityTypeIdentifier: .dietaryChromium, unit: .gramUnit(with: .micro)) { micronutrientValue($0, id: "chromium") },
        SampleDefinition(key: "dietaryCopper", quantityTypeIdentifier: .dietaryCopper, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "copper") },
        SampleDefinition(key: "dietaryFatMonounsaturated", quantityTypeIdentifier: .dietaryFatMonounsaturated, unit: .gram()) { micronutrientValue($0, id: "monounsaturated_fat") },
        SampleDefinition(key: "dietaryFatPolyunsaturated", quantityTypeIdentifier: .dietaryFatPolyunsaturated, unit: .gram()) { micronutrientValue($0, id: "polyunsaturated_fat") },
        SampleDefinition(key: "dietaryFiber", quantityTypeIdentifier: .dietaryFiber, unit: .gram()) { micronutrientValue($0, id: "fiber") },
        SampleDefinition(key: "dietaryFolate", quantityTypeIdentifier: .dietaryFolate, unit: .gramUnit(with: .micro)) { micronutrientValue($0, id: "folate") },
        SampleDefinition(key: "dietaryIodine", quantityTypeIdentifier: .dietaryIodine, unit: .gramUnit(with: .micro)) { micronutrientValue($0, id: "iodine") },
        SampleDefinition(key: "dietaryMagnesium", quantityTypeIdentifier: .dietaryMagnesium, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "magnesium") },
        SampleDefinition(key: "dietaryManganese", quantityTypeIdentifier: .dietaryManganese, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "manganese") },
        SampleDefinition(key: "dietaryMolybdenum", quantityTypeIdentifier: .dietaryMolybdenum, unit: .gramUnit(with: .micro)) { micronutrientValue($0, id: "molybdenum") },
        SampleDefinition(key: "dietaryNiacin", quantityTypeIdentifier: .dietaryNiacin, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "niacin") },
        SampleDefinition(key: "dietaryPantothenicAcid", quantityTypeIdentifier: .dietaryPantothenicAcid, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "pantothenic_acid") },
        SampleDefinition(key: "dietaryPhosphorus", quantityTypeIdentifier: .dietaryPhosphorus, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "phosphorus") },
        SampleDefinition(key: "dietaryRiboflavin", quantityTypeIdentifier: .dietaryRiboflavin, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "riboflavin") },
        SampleDefinition(key: "dietarySelenium", quantityTypeIdentifier: .dietarySelenium, unit: .gramUnit(with: .micro)) { micronutrientValue($0, id: "selenium") },
        SampleDefinition(key: "dietarySugar", quantityTypeIdentifier: .dietarySugar, unit: .gram()) { micronutrientValue($0, id: "sugar", aliases: ["Sugar", "Total Sugar", "Total Sugars"]) },
        SampleDefinition(key: "dietaryThiamin", quantityTypeIdentifier: .dietaryThiamin, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "thiamin", aliases: ["Thiamine"]) },
        SampleDefinition(key: "dietarySodium", quantityTypeIdentifier: .dietarySodium, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "sodium") },
        SampleDefinition(key: "dietaryCholesterol", quantityTypeIdentifier: .dietaryCholesterol, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "cholesterol") },
        SampleDefinition(key: "dietaryFatSaturated", quantityTypeIdentifier: .dietaryFatSaturated, unit: .gram()) { micronutrientValue($0, id: "saturated_fat") },
        SampleDefinition(key: "dietaryVitaminA", quantityTypeIdentifier: .dietaryVitaminA, unit: .gramUnit(with: .micro)) { micronutrientValue($0, id: "vitamin_a") },
        SampleDefinition(key: "dietaryVitaminB6", quantityTypeIdentifier: .dietaryVitaminB6, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "vitamin_b6") },
        SampleDefinition(key: "dietaryVitaminB12", quantityTypeIdentifier: .dietaryVitaminB12, unit: .gramUnit(with: .micro)) { micronutrientValue($0, id: "vitamin_b12") },
        SampleDefinition(key: "dietaryVitaminC", quantityTypeIdentifier: .dietaryVitaminC, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "vitamin_c") },
        SampleDefinition(key: "dietaryVitaminD", quantityTypeIdentifier: .dietaryVitaminD, unit: .gramUnit(with: .micro)) { micronutrientValue($0, id: "vitamin_d") },
        SampleDefinition(key: "dietaryVitaminE", quantityTypeIdentifier: .dietaryVitaminE, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "vitamin_e") },
        SampleDefinition(key: "dietaryVitaminK", quantityTypeIdentifier: .dietaryVitaminK, unit: .gramUnit(with: .micro)) { micronutrientValue($0, id: "vitamin_k") },
        SampleDefinition(key: "dietaryWater", quantityTypeIdentifier: .dietaryWater, unit: .literUnit(with: .milli)) { micronutrientValue($0, id: "water") },
        SampleDefinition(key: "dietaryCalcium", quantityTypeIdentifier: .dietaryCalcium, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "calcium") },
        SampleDefinition(key: "dietaryIron", quantityTypeIdentifier: .dietaryIron, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "iron") },
        SampleDefinition(key: "dietaryPotassium", quantityTypeIdentifier: .dietaryPotassium, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "potassium") },
        SampleDefinition(key: "dietaryZinc", quantityTypeIdentifier: .dietaryZinc, unit: .gramUnit(with: .milli)) { micronutrientValue($0, id: "zinc") },
    ]

    static let unsupportedNutritionExportKeys: [String] = [
        "added_sugars",
        "trans_fat"
    ]

    private static func micronutrientValue(
        _ entry: NutritionEntry,
        id: String,
        aliases: [String] = []
    ) -> Double? {
        KnownMicronutrients.value(in: entry.micronutrients, forID: id, aliases: aliases)?.value
    }

    static var healthKitSampleDefinitionKeys: [String] {
        sampleDefinitions.map(\.key)
    }

    static func healthKitSampleValue(for entry: NutritionEntry, sampleKey: String) -> Double? {
        sampleDefinitions.first { $0.key == sampleKey }?.value(entry)
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
            if force {
                try await deleteLegacySamples(for: entry)
            }
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
        await deleteSamples(forEntryID: entry.id)
    }

    /// Deletes deterministic samples without retaining a SwiftData model that
    /// may already have been removed from its context.
    @discardableResult
    func deleteSamples(forEntryID entryID: UUID) async -> SyncResult {
        guard isAvailable, isAuthorized else { return .skipped }

        do {
            try await deleteExistingSamples(forEntryID: entryID)
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
        try await deleteExistingSamples(forEntryID: entry.id)
    }

    private func deleteExistingSamples(forEntryID entryID: UUID) async throws {
        for definition in Self.sampleDefinitions {
            guard let type = HKQuantityType.quantityType(forIdentifier: definition.quantityTypeIdentifier) else { continue }
            let samples = try await samples(
                type: type,
                syncIdentifier: syncIdentifier(for: entryID, sampleKey: definition.key)
            )
            if !samples.isEmpty {
                try await store.delete(samples)
            }
        }
    }

    private func deleteLegacySamples(for entry: NutritionEntry) async throws {
        let candidateDates = legacySampleCandidateDates(for: entry)

        for definition in Self.sampleDefinitions {
            guard let type = HKQuantityType.quantityType(forIdentifier: definition.quantityTypeIdentifier),
                  definition.value(entry) != nil else { continue }

            for date in candidateDates {
                let samples = try await legacySamples(
                    type: type,
                    foodType: entry.name,
                    dayContaining: date
                )
                if !samples.isEmpty {
                    try await store.delete(samples)
                }
            }
        }
    }

    private func legacySampleCandidateDates(for entry: NutritionEntry) -> [Date] {
        let dates = [entry.healthKitSampleTimestamp, entry.timestamp]
        return dates.reduce(into: [Date]()) { result, date in
            let alreadyIncluded = result.contains { abs($0.timeIntervalSince(date)) < 0.001 }
            if !alreadyIncluded {
                result.append(date)
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

    private func legacySamples(
        type: HKQuantityType,
        foodType: String,
        dayContaining date: Date
    ) async throws -> [HKSample] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return []
        }
        let datePredicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: .strictStartDate
        )
        let foodPredicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeyFoodType,
            operatorType: .equalTo,
            value: foodType
        )
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            datePredicate,
            foodPredicate
        ])

        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], any Error>) in
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

        let appBundleIdentifier = Bundle.main.bundleIdentifier
        return samples.filter { sample in
            let metadata = sample.metadata ?? [:]
            let hasCurrentSyncID = metadata[HKMetadataKeySyncIdentifier] != nil
            let hasCurrentEntryID = metadata["OpenFoodJournalEntryID"] != nil
            let hasCurrentNutrientKey = metadata["OpenFoodJournalNutrient"] != nil
            let wasWrittenByThisApp = sample.sourceRevision.source.bundleIdentifier == appBundleIdentifier
            return wasWrittenByThisApp && !hasCurrentSyncID && !hasCurrentEntryID && !hasCurrentNutrientKey
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

extension HealthKitService: NutritionEntryHealthSyncing {
    func syncNutritionEntry(_ entry: NutritionEntry, in modelContext: ModelContext) async {
        _ = await sync(entry, in: modelContext)
    }

    func deleteNutritionSamples(forEntryID entryID: UUID) async {
        _ = await deleteSamples(forEntryID: entryID)
    }
}
