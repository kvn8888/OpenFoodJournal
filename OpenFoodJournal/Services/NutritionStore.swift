// Macros — Food Journaling App
// AGPL-3.0 License

import Foundation
import SwiftData
import Observation

/// Provider-neutral boundary for Apple Health side effects caused by journal
/// mutations. Keeping this beside the persistence boundary means every caller
/// (views, Assistant tools, and future App Intents) can share one
/// mutation contract instead of remembering a second HealthKit call.
@MainActor
protocol NutritionEntryHealthSyncing: AnyObject {
    func syncNutritionEntry(_ entry: NutritionEntry, in modelContext: ModelContext) async
    func deleteNutritionSamples(forEntryID entryID: UUID) async
}

enum JournalFoodBankSaveResult {
    case saved(SavedFood)
    case alreadySaved(SavedFood)
    case failed
}

@Observable
@MainActor
final class NutritionStore {
    @ObservationIgnored
    let modelContext: ModelContext
    @ObservationIgnored
    private let tursoMirror: TursoMirrorService?
    @ObservationIgnored
    private let healthSyncer: (any NutritionEntryHealthSyncing)?
    @ObservationIgnored
    private let isHealthSyncEnabled: () -> Bool
    @ObservationIgnored
    private weak var foodImageGenerationQueue: (any SavedFoodImageGenerationQueuing)?
    /// Bumped on every write so SwiftUI views that read it re-evaluate their computed properties
    private(set) var changeCount = 0

    init(
        modelContext: ModelContext,
        tursoMirror: TursoMirrorService? = nil,
        healthSyncer: (any NutritionEntryHealthSyncing)? = nil,
        isHealthSyncEnabled: @escaping () -> Bool = { false }
    ) {
        self.modelContext = modelContext
        self.tursoMirror = tursoMirror
        self.healthSyncer = healthSyncer
        self.isHealthSyncEnabled = isHealthSyncEnabled
    }

    /// Connects the persistence boundary to the app's configured image
    /// generator after both services have been constructed.
    func configureFoodImageGenerationQueue(_ queue: any SavedFoodImageGenerationQueuing) {
        foodImageGenerationQueue = queue
    }

    /// Canonical creation path for user-created Food Bank items. Generation is
    /// requested only after SwiftData has saved the food successfully, so the
    /// queue never points at an item that failed to persist.
    @discardableResult
    func addSavedFood(_ food: SavedFood, mirrorReason: String = "saved_food_created") -> Bool {
        modelContext.insert(food)
        guard save(mirrorReason: mirrorReason) else { return false }
        foodImageGenerationQueue?.enqueueFoodIconImageGeneration(for: food.id)
        return true
    }

    /// Copy exactly the logged portion, not the original template's baseline.
    /// Never repoint savedFoodID: it may identify the calculator that produced
    /// this entry. The reverse source ID deduplicates repeated save gestures.
    func saveJournalEntryToFoodBank(_ entry: NutritionEntry) -> JournalFoodBankSaveResult {
        let entryID = entry.id
        var descriptor = FetchDescriptor<SavedFood>(predicate: #Predicate { $0.sourceJournalEntryID == entryID })
        descriptor.fetchLimit = 1
        do {
            if let existing = try modelContext.fetch(descriptor).first {
                if existing.isArchivedInFoodBank {
                    let oldArchivedAt = existing.archivedAt
                    let oldLastUsedAt = existing.lastUsedAt
                    existing.restoreFromFoodBankArchive()
                    guard save(mirrorReason: "journal_food_restored") else {
                        existing.archivedAt = oldArchivedAt
                        existing.lastUsedAt = oldLastUsedAt
                        return .failed
                    }
                }
                return .alreadySaved(existing)
            }
        } catch {
            return .failed
        }
        let food = SavedFood(from: entry)
        food.sourceJournalEntryID = entry.id
        guard addSavedFood(food, mirrorReason: "journal_food_saved") else {
            modelContext.delete(food)
            return .failed
        }
        return .saved(food)
    }

    @discardableResult
    func saveCalculatorCustomization(
        for calculator: SavedFood,
        name: String,
        selections: [CalculatorSelection]
    ) -> Bool {
        let previous = calculator.calculatorCustomizations
        guard calculator.rememberCalculatorCustomization(name: name, selections: selections) else { return false }
        guard save(mirrorReason: "calculator_customization_saved") else {
            calculator.calculatorCustomizations = previous
            return false
        }
        return true
    }

    @discardableResult
    func deleteCalculatorCustomization(_ id: UUID, from calculator: SavedFood) -> Bool {
        let previous = calculator.calculatorCustomizations
        calculator.calculatorCustomizations.removeAll { $0.id == id }
        guard save(mirrorReason: "calculator_customization_deleted") else {
            calculator.calculatorCustomizations = previous
            return false
        }
        return true
    }

    /// A single persistence boundary remembers reusable choices alongside the
    /// newly logged nutrition snapshot. Reusing a preset never logs by itself.
    @discardableResult
    func logCalculatorBuild(
        from calculator: SavedFood,
        name: String,
        selections: [CalculatorSelection],
        mealType: MealType,
        to date: Date
    ) -> Bool {
        let previous = calculator.calculatorCustomizations
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard calculator.rememberCalculatorCustomization(name: name, selections: selections) else { return false }
        let totals = SavedFood.calculatorTotals(for: calculator.calculatorIngredients, selections: selections)
        let entry = NutritionEntry(
            name: name, mealType: mealType, scanMode: .manual,
            calories: totals.calories, protein: totals.protein, carbs: totals.carbs, fat: totals.fat,
            micronutrients: totals.micronutrients, servingSize: "1 meal",
            brand: calculator.brand ?? calculator.name, servingQuantity: 1, servingUnit: "meal",
            savedFoodID: calculator.id
        )
        entry.selectionSummary = SavedFood.calculatorSelectionSummary(
            for: calculator.calculatorIngredients, selections: selections
        )
        guard log(entry, to: date) else {
            calculator.calculatorCustomizations = previous
            modelContext.delete(entry)
            return false
        }
        return true
    }

    // MARK: - Log Entry

    @discardableResult
    func log(_ entry: NutritionEntry, to date: Date) -> Bool {
        let log = fetchOrCreateLog(for: date)
        entry.timestamp = Self.timestamp(on: date, preservingTimeFrom: entry.timestamp)
        modelContext.insert(entry)
        link(entry, to: log)
        markHealthKitSyncStaleIfNeeded(entry)
        refreshSavedFoodUsageIfLinked(to: entry)
        guard save() else { return false }
        scheduleHealthSync(for: entry)
        return true
    }

    /// Logs a food portion that has already been fully measured with an
    /// empty-container tare. Unlike gross-weight tracking, this is a complete
    /// journal mutation and must not create a pending TrackedContainer.
    @discardableResult
    func logTaredFood(
        _ plan: TareFoodLogPlan,
        from food: SavedFood,
        mealType: MealType,
        to date: Date
    ) -> NutritionEntry {
        let entry = plan.makeNutritionEntry(from: food, mealType: mealType)
        log(entry, to: date)
        return entry
    }

    private func refreshSavedFoodUsageIfLinked(to entry: NutritionEntry) {
        guard let foodID = entry.savedFoodID else { return }

        var descriptor = FetchDescriptor<SavedFood>(
            predicate: #Predicate { $0.id == foodID }
        )
        descriptor.fetchLimit = 1

        if let food = try? modelContext.fetch(descriptor).first {
            food.markLoggedForFoodBank()
        }
    }

    // MARK: - Fetch

    func fetchLog(for date: Date) -> DailyLog? {
        let startOfDay = Calendar.current.startOfDay(for: date)
        let descriptor = FetchDescriptor<DailyLog>(
            predicate: #Predicate { $0.date == startOfDay }
        )
        guard let logs = try? modelContext.fetch(descriptor) else { return nil }

        // CloudKit can briefly produce duplicate DailyLog rows for the same day.
        // Prefer the populated row so the journal does not appear empty.
        return logs.sorted { lhs, rhs in
            let lhsCount = lhs.safeEntries.count
            let rhsCount = rhs.safeEntries.count
            if lhsCount != rhsCount {
                return lhsCount > rhsCount
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }.first
    }

    func fetchLogs(from startDate: Date, to endDate: Date) -> [DailyLog] {
        let start = Calendar.current.startOfDay(for: startDate)
        let end = Calendar.current.startOfDay(for: endDate)
        let descriptor = FetchDescriptor<DailyLog>(
            predicate: #Predicate { $0.date >= start && $0.date <= end },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func fetchAllLogs() -> [DailyLog] {
        let descriptor = FetchDescriptor<DailyLog>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func fetchAllEntries() -> [NutritionEntry] {
        let descriptor = FetchDescriptor<NutritionEntry>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func entriesNeedingHealthSync() -> [NutritionEntry] {
        _ = changeCount
        return fetchAllEntries().filter { entry in
            entry.healthKitSyncStatus != HealthKitSyncStatus.synced ||
            entry.healthKitLastWriteHash != entry.healthKitWriteHash
        }
    }

    // MARK: - Delete

    func delete(_ entry: NutritionEntry) {
        let entryID = entry.id
        modelContext.delete(entry)
        if save() {
            scheduleHealthDelete(forEntryID: entryID)
        }
    }

    func delete(_ log: DailyLog) {
        let entryIDs = log.safeEntries.map(\.id)
        modelContext.delete(log)
        if save() {
            for entryID in entryIDs {
                scheduleHealthDelete(forEntryID: entryID)
            }
        }
    }

    // MARK: - Export

    /// Exports logged entries as spreadsheet-friendly CSV.
    /// This is intentionally analytical, not the restore-grade backup format.
    /// Data comes from the local SwiftData store which CloudKit keeps in sync with iCloud.
    func exportCSV() -> String {
        // Fetch all entries directly — avoids missing orphaned entries not linked to a log
        let entryDescriptor = FetchDescriptor<NutritionEntry>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        let allEntries = (try? modelContext.fetch(entryDescriptor)) ?? []
        guard !allEntries.isEmpty else { return "" }

        // Collect all unique micronutrient names across every entry
        var allMicroNames = Set<String>()
        for entry in allEntries {
            allMicroNames.formUnion(entry.micronutrients.keys)
        }
        let sortedMicroNames = allMicroNames.sorted()

        // Build header: fixed columns + dynamic micro columns.
        var header = [
            "Entry ID", "Daily Log ID", "Log Date", "Entry Timestamp",
            "Meal", "Name", "Brand", "Scan Mode", "Confidence %",
            "Calories", "Protein (g)", "Carbs (g)", "Fat (g)",
            "Serving Size", "Selection Summary", "Servings Per Container", "Serving Count",
            "Serving Qty", "Serving Unit", "Saved Food ID", "Scan Duration Ms"
        ]
        header.append(contentsOf: sortedMicroNames)
        var rows: [String] = [header.map(Self.csvEscape).joined(separator: ",")]

        for entry in allEntries {
            let logDate = entry.dailyLog?.date ?? entry.timestamp
            let confidence = entry.confidence.map { Self.decimal($0 * 100, digits: 0) } ?? ""
            var fields: [String] = []
            fields.append(entry.id.uuidString)
            fields.append(entry.dailyLog?.id.uuidString ?? "")
            fields.append(Self.isoDateFormatter.string(from: logDate))
            fields.append(Self.isoTimestampFormatter.string(from: entry.timestamp))
            fields.append(entry.mealType.rawValue)
            fields.append(entry.name)
            fields.append(entry.brand ?? "")
            fields.append(entry.scanMode.rawValue)
            fields.append(confidence)
            fields.append(Self.decimal(entry.calories))
            fields.append(Self.decimal(entry.protein))
            fields.append(Self.decimal(entry.carbs))
            fields.append(Self.decimal(entry.fat))
            fields.append(entry.servingSize ?? "")
            fields.append(entry.selectionSummary ?? "")
            fields.append(entry.servingsPerContainer.map { Self.decimal($0) } ?? "")
            fields.append(Self.decimal(entry.servingCount, digits: 2))
            fields.append(entry.servingQuantity.map { Self.decimal($0, digits: 2) } ?? "")
            fields.append(entry.servingUnit ?? "")
            fields.append(entry.savedFoodID?.uuidString ?? "")
            fields.append(entry.scanDurationMs.map(String.init) ?? "")

            // Append each micronutrient value (or empty if entry doesn't have it)
            for microName in sortedMicroNames {
                if let micro = entry.micronutrients[microName] {
                    fields.append("\(Self.decimal(micro.value)) \(micro.unit)")
                } else {
                    fields.append("")
                }
            }
            rows.append(fields.map(Self.csvEscape).joined(separator: ","))
        }

        return rows.joined(separator: "\n")
    }

    private static func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func decimal(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()

    private static let isoTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Backup Export / Import

    func exportBackup(goals: UserGoals, appSettings: AppSettingsRecord) throws -> Data {
        let dailyLogs = (try? modelContext.fetch(
            FetchDescriptor<DailyLog>(sortBy: [SortDescriptor(\.date, order: .forward)])
        )) ?? []
        let entries = (try? modelContext.fetch(
            FetchDescriptor<NutritionEntry>(sortBy: [SortDescriptor(\.timestamp, order: .forward)])
        )) ?? []
        let savedFoods = (try? modelContext.fetch(
            FetchDescriptor<SavedFood>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        )) ?? []
        let containers = (try? modelContext.fetch(
            FetchDescriptor<TrackedContainer>(sortBy: [SortDescriptor(\.startDate, order: .forward)])
        )) ?? []

        let backup = OpenFoodJournalBackup(
            schemaVersion: OpenFoodJournalBackup.currentSchemaVersion,
            exportedAt: .now,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            dailyLogs: dailyLogs.map(DailyLogRecord.init),
            nutritionEntries: entries.map(NutritionEntryRecord.init),
            savedFoods: savedFoods.map(SavedFoodRecord.init),
            trackedContainers: containers.map(TrackedContainerRecord.init),
            preferences: PreferencesRecord(Preferences.current(in: modelContext)),
            userGoals: UserGoalsRecord(goals: goals),
            appSettings: appSettings
        )

        return try backup.encodedData()
    }

    func importBackup(_ backup: OpenFoodJournalBackup, goals: UserGoals) throws -> BackupImportSummary {
        guard backup.schemaVersion <= OpenFoodJournalBackup.currentSchemaVersion else {
            throw BackupImportError.unsupportedSchemaVersion(backup.schemaVersion)
        }

        var summary = BackupImportSummary()

        var logsByID = keyedByID((try? modelContext.fetch(FetchDescriptor<DailyLog>())) ?? []) { $0.id }
        var foodsByID = keyedByID((try? modelContext.fetch(FetchDescriptor<SavedFood>())) ?? []) { $0.id }
        var entriesByID = keyedByID((try? modelContext.fetch(FetchDescriptor<NutritionEntry>())) ?? []) { $0.id }
        var containersByID = keyedByID((try? modelContext.fetch(FetchDescriptor<TrackedContainer>())) ?? []) { $0.id }

        for record in backup.dailyLogs {
            if let log = logsByID[record.id] {
                log.date = record.date.startOfDay
                log.notes = record.notes
                summary.updatedDailyLogs += 1
            } else {
                let log = DailyLog(date: record.date, id: record.id, notes: record.notes)
                modelContext.insert(log)
                logsByID[record.id] = log
                summary.insertedDailyLogs += 1
            }
        }

        for record in backup.savedFoods {
            if let food = foodsByID[record.id] {
                record.apply(to: food)
                summary.updatedSavedFoods += 1
            } else {
                let food = record.makeModel()
                modelContext.insert(food)
                foodsByID[record.id] = food
                summary.insertedSavedFoods += 1
            }
        }

        for record in backup.nutritionEntries {
            let entry: NutritionEntry
            if let existing = entriesByID[record.id] {
                entry = existing
                record.apply(to: entry)
                summary.updatedEntries += 1
            } else {
                entry = record.makeModel()
                modelContext.insert(entry)
                entriesByID[record.id] = entry
                summary.insertedEntries += 1
            }

            if let logID = record.dailyLogID, let log = logsByID[logID] {
                link(entry, to: log)
            } else {
                unlinkFromDailyLog(entry)
            }
        }

        for record in backup.trackedContainers {
            if let container = containersByID[record.id] {
                record.apply(to: container)
                summary.updatedContainers += 1
            } else {
                let container = record.makeModel()
                modelContext.insert(container)
                containersByID[record.id] = container
                summary.insertedContainers += 1
            }
        }

        if let preferencesRecord = backup.preferences {
            preferencesRecord.apply(to: Preferences.current(in: modelContext))
        }
        backup.userGoals.apply(to: goals)

        save()
        return summary
    }

    // MARK: - Save (public for use in edit flows)

    func saveChanges(mirrorReason: String = "nutrition_store_save") {
        save(mirrorReason: mirrorReason)
    }

    /// Finds the most recent quantity and unit used for this Food Bank item.
    /// Prefer the durable SavedFood link, then fall back to name + brand for
    /// journal entries created before savedFoodID was recorded.
    func lastUsedServing(for food: SavedFood) -> (quantity: Double, unit: String)? {
        let foodID = food.id
        var descriptor = FetchDescriptor<NutritionEntry>(
            predicate: #Predicate { $0.savedFoodID == foodID },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        if let entry = try? modelContext.fetch(descriptor).first,
           let serving = validServing(from: entry) {
            return serving
        }

        let name = food.name
        let legacyDescriptor = FetchDescriptor<NutritionEntry>(
            predicate: #Predicate { $0.name == name },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let normalizedBrand = Self.normalizedBrand(food.brand)
        guard let legacyEntry = try? modelContext.fetch(legacyDescriptor).first(where: {
            Self.normalizedBrand($0.brand) == normalizedBrand
        }) else {
            return nil
        }
        return validServing(from: legacyEntry)
    }

    private func validServing(from entry: NutritionEntry) -> (quantity: Double, unit: String)? {
        guard let quantity = entry.servingQuantity, quantity > 0,
              let unit = entry.servingUnit?.trimmingCharacters(in: .whitespacesAndNewlines),
              !unit.isEmpty else {
            return nil
        }
        return (quantity, unit)
    }

    private static func normalizedBrand(_ brand: String?) -> String {
        brand?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    /// Save an entry's edits locally
    func saveEntry(_ entry: NutritionEntry) {
        markHealthKitSyncStaleIfNeeded(entry)
        if save() {
            scheduleHealthSync(for: entry)
        }
    }

    // MARK: - Serving Mapping Propagation

    /// Deduplicates a mappings array so there's at most one mapping per `from.unit`.
    /// When duplicates exist, the last one wins (most recently added/edited).
    static func dedupMappings(_ mappings: [ServingMapping]) -> [ServingMapping] {
        var seen: [String: Int] = [:]  // from.unit → index in result
        var result: [ServingMapping] = []
        for mapping in mappings {
            let key = mapping.from.unit.lowercased().trimmingCharacters(in: .whitespaces)
            if let existingIndex = seen[key] {
                // Replace the earlier mapping with this newer one
                result[existingIndex] = mapping
            } else {
                seen[key] = result.count
                result.append(mapping)
            }
        }
        return result
    }

    /// Updates a SavedFood's mappings and propagates to all linked NutritionEntries.
    /// Call this when the user edits mappings on a SavedFood (e.g. in LogFoodSheet).
    func updateMappings(on food: SavedFood, to newMappings: [ServingMapping]) {
        let deduped = Self.dedupMappings(newMappings)
        food.servingMappings = deduped

        // Propagate to all entries linked to this food
        let foodID = food.id
        let descriptor = FetchDescriptor<NutritionEntry>(
            predicate: #Predicate { $0.savedFoodID == foodID }
        )
        if let entries = try? modelContext.fetch(descriptor) {
            for entry in entries {
                entry.servingMappings = deduped
            }
        }
        save()
    }

    /// Updates an entry's mappings and propagates back to its SavedFood + sibling entries.
    /// Call this when the user edits mappings on a NutritionEntry (e.g. in EditEntryView).
    func updateMappings(on entry: NutritionEntry, to newMappings: [ServingMapping]) {
        let deduped = Self.dedupMappings(newMappings)
        entry.servingMappings = deduped

        // Propagate back to the SavedFood and all sibling entries
        guard let foodID = entry.savedFoodID else {
            save()
            return
        }

        // Find and update the parent SavedFood
        let foodDescriptor = FetchDescriptor<SavedFood>(
            predicate: #Predicate { $0.id == foodID }
        )
        if let food = try? modelContext.fetch(foodDescriptor).first {
            food.servingMappings = deduped
        }

        // Update all sibling entries (same savedFoodID, different id)
        let entryID = entry.id
        let entryDescriptor = FetchDescriptor<NutritionEntry>(
            predicate: #Predicate { $0.savedFoodID == foodID && $0.id != entryID }
        )
        if let siblings = try? modelContext.fetch(entryDescriptor) {
            for sibling in siblings {
                sibling.servingMappings = deduped
            }
        }
        save()
    }

    /// Adds a new mapping (or replaces an existing one with the same from.unit)
    /// on a SavedFood and propagates to all linked entries.
    func addMapping(_ mapping: ServingMapping, to food: SavedFood) {
        var current = food.servingMappings
        current.append(mapping)
        updateMappings(on: food, to: current)
    }

    /// Adds a new mapping (or replaces an existing one with the same from.unit)
    /// on an entry and propagates to SavedFood + siblings.
    func addMapping(_ mapping: ServingMapping, to entry: NutritionEntry) {
        var current = entry.servingMappings
        current.append(mapping)
        updateMappings(on: entry, to: current)
    }

    /// Replaces a mapping at a specific index on a SavedFood and propagates.
    func replaceMapping(at index: Int, with mapping: ServingMapping, on food: SavedFood) {
        guard index < food.servingMappings.count else { return }
        var current = food.servingMappings
        current[index] = mapping
        updateMappings(on: food, to: current)
    }

    /// Replaces a mapping at a specific index on an entry and propagates.
    func replaceMapping(at index: Int, with mapping: ServingMapping, on entry: NutritionEntry) {
        guard index < entry.servingMappings.count else { return }
        var current = entry.servingMappings
        current[index] = mapping
        updateMappings(on: entry, to: current)
    }

    // MARK: - Retrolink Old Entries

    /// One-time migration: links existing NutritionEntries that have no savedFoodID
    /// to their matching SavedFood by name + brand. Call once on app launch.
    func retrolinkOrphanedEntries() {
        // Fetch all entries without a savedFoodID
        let entryDescriptor = FetchDescriptor<NutritionEntry>(
            predicate: #Predicate { $0.savedFoodID == nil }
        )
        guard let orphans = try? modelContext.fetch(entryDescriptor), !orphans.isEmpty else { return }

        // Build a lookup table of SavedFoods by (lowercased name, lowercased brand)
        let foodDescriptor = FetchDescriptor<SavedFood>()
        guard let foods = try? modelContext.fetch(foodDescriptor) else { return }

        // Key: "name|brand" (both lowercased)
        var foodLookup: [String: SavedFood] = [:]
        for food in foods {
            let key = "\(food.name.lowercased())|\(food.brand?.lowercased() ?? "")"
            foodLookup[key] = food
        }

        var linked = 0
        for entry in orphans {
            let key = "\(entry.name.lowercased())|\(entry.brand?.lowercased() ?? "")"
            if let food = foodLookup[key] {
                entry.savedFoodID = food.id
                // Also sync mappings from the SavedFood (source of truth)
                entry.servingMappings = food.servingMappings
                linked += 1
            }
        }

        if linked > 0 {
            save()
        }
    }

    /// Idempotent repair: keeps historical NutritionEntry rows reachable from
    /// their DailyLog so day views and aggregates match direct-entry exports.
    @discardableResult
    func repairDailyLogEntryRelationships() -> Int {
        let entryDescriptor = FetchDescriptor<NutritionEntry>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        guard let entries = try? modelContext.fetch(entryDescriptor), !entries.isEmpty else { return 0 }

        var repaired = 0
        for entry in entries {
            let targetDate = entry.dailyLog?.date ?? entry.timestamp
            let targetLog = fetchOrCreateLog(for: targetDate)
            let targetEntries = targetLog.entries ?? []
            let relationshipIsCorrect = entry.dailyLog?.id == targetLog.id
            let occurrenceCount = targetEntries.filter { $0.id == entry.id }.count

            if !relationshipIsCorrect || occurrenceCount != 1 {
                link(entry, to: targetLog)
                repaired += 1
            }
        }

        if repaired > 0 {
            save()
        }
        return repaired
    }

    /// One-time migration: deduplicates serving mappings on all SavedFoods and their
    /// linked entries. Ensures only one mapping per from.unit exists.
    func deduplicateAllMappings() {
        let foodDescriptor = FetchDescriptor<SavedFood>()
        guard let foods = try? modelContext.fetch(foodDescriptor) else { return }

        var changed = false
        for food in foods where food.servingMappings.count > 1 {
            let deduped = Self.dedupMappings(food.servingMappings)
            if deduped.count != food.servingMappings.count {
                food.servingMappings = deduped
                changed = true
            }
        }

        let entryDescriptor = FetchDescriptor<NutritionEntry>()
        if let entries = try? modelContext.fetch(entryDescriptor) {
            for entry in entries where entry.servingMappings.count > 1 {
                let deduped = Self.dedupMappings(entry.servingMappings)
                if deduped.count != entry.servingMappings.count {
                    entry.servingMappings = deduped
                    changed = true
                }
            }
        }

        if changed { save() }
    }

    /// Move an entry to a different day's log (used when the user changes the date in EditEntryView)
    func moveEntry(_ entry: NutritionEntry, to newDate: Date) {
        let newLog = fetchOrCreateLog(for: newDate)
        entry.timestamp = Self.timestamp(on: newDate, preservingTimeFrom: entry.timestamp)
        link(entry, to: newLog)
        markHealthKitSyncStaleIfNeeded(entry)
        if save() {
            scheduleHealthSync(for: entry)
        }
    }

    // MARK: - Micronutrient Aggregation

    /// The time period for aggregating micronutrient data
    enum TimePeriod: String, CaseIterable {
        case daily = "Day"
        case weekly = "Week"
        case monthly = "Month"
    }

    /// Aggregates all micronutrient values across entries in the given time period.
    /// Returns a dictionary of nutrient ID → total MicronutrientValue.
    /// For weekly/monthly, the values are per-day averages (total ÷ number of days in period).
    func aggregateMicronutrients(period: TimePeriod, referenceDate: Date = .now) -> [String: MicronutrientValue] {
        let calendar = Calendar.current
        let logs: [DailyLog]
        let dayCount: Double

        switch period {
        case .daily:
            // Just today's log
            if let log = fetchLog(for: referenceDate) {
                logs = [log]
            } else {
                logs = []
            }
            dayCount = 1

        case .weekly:
            // Last 7 days
            let start = calendar.date(byAdding: .day, value: -6, to: referenceDate) ?? referenceDate
            logs = fetchLogs(from: start, to: referenceDate)
            dayCount = 7

        case .monthly:
            // Last 30 days
            let start = calendar.date(byAdding: .day, value: -29, to: referenceDate) ?? referenceDate
            logs = fetchLogs(from: start, to: referenceDate)
            dayCount = 30
        }

        // Sum all micronutrient values across all entries in the fetched logs
        var totals: [String: (value: Double, unit: String)] = [:]
        for log in logs {
            for entry in log.safeEntries {
                for (key, micro) in entry.micronutrients {
                    if let existing = totals[key] {
                        totals[key] = (existing.value + micro.value, micro.unit)
                    } else {
                        totals[key] = (micro.value, micro.unit)
                    }
                }
            }
        }

        // For daily view, return raw totals. For weekly/monthly, return daily average.
        let divisor = period == .daily ? 1.0 : dayCount
        var result: [String: MicronutrientValue] = [:]
        for (key, total) in totals {
            result[key] = MicronutrientValue(
                value: total.value / divisor,
                unit: total.unit
            )
        }

        return result
    }

    /// Aggregates macro totals across entries in the given time period.
    /// For weekly/monthly returns daily averages.
    func aggregateMacros(period: TimePeriod, referenceDate: Date = .now) -> (cal: Double, protein: Double, carbs: Double, fat: Double) {
        let calendar = Calendar.current
        let logs: [DailyLog]
        let dayCount: Double

        switch period {
        case .daily:
            if let log = fetchLog(for: referenceDate) {
                logs = [log]
            } else {
                logs = []
            }
            dayCount = 1
        case .weekly:
            let start = calendar.date(byAdding: .day, value: -6, to: referenceDate) ?? referenceDate
            logs = fetchLogs(from: start, to: referenceDate)
            dayCount = 7
        case .monthly:
            let start = calendar.date(byAdding: .day, value: -29, to: referenceDate) ?? referenceDate
            logs = fetchLogs(from: start, to: referenceDate)
            dayCount = 30
        }

        var cal = 0.0, protein = 0.0, carbs = 0.0, fat = 0.0
        for log in logs {
            for entry in log.safeEntries {
                cal += entry.calories
                protein += entry.protein
                carbs += entry.carbs
                fat += entry.fat
            }
        }

        let divisor = period == .daily ? 1.0 : dayCount
        return (cal / divisor, protein / divisor, carbs / divisor, fat / divisor)
    }

    /// Returns all entries within the given time period, for per-food breakdowns.
    func entriesForPeriod(_ period: TimePeriod, referenceDate: Date = .now) -> [NutritionEntry] {
        let calendar = Calendar.current
        let logs: [DailyLog]

        switch period {
        case .daily:
            if let log = fetchLog(for: referenceDate) {
                logs = [log]
            } else {
                logs = []
            }
        case .weekly:
            let start = calendar.date(byAdding: .day, value: -6, to: referenceDate) ?? referenceDate
            logs = fetchLogs(from: start, to: referenceDate)
        case .monthly:
            let start = calendar.date(byAdding: .day, value: -29, to: referenceDate) ?? referenceDate
            logs = fetchLogs(from: start, to: referenceDate)
        }

        return logs.flatMap(\.safeEntries)
    }

    // MARK: - Private

    private func keyedByID<T>(_ items: [T], id: (T) -> UUID) -> [UUID: T] {
        var result: [UUID: T] = [:]
        for item in items {
            result[id(item)] = item
        }
        return result
    }

    private func link(_ entry: NutritionEntry, to log: DailyLog) {
        if entry.dailyLog?.id != log.id {
            unlinkFromDailyLog(entry)
        }

        entry.dailyLog = log
        var entries = log.entries ?? []
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        log.entries = entries
    }

    private func unlinkFromDailyLog(_ entry: NutritionEntry) {
        guard let oldLog = entry.dailyLog else { return }
        var entries = oldLog.entries ?? []
        entries.removeAll { $0.id == entry.id }
        oldLog.entries = entries
        entry.dailyLog = nil
    }

    private func fetchOrCreateLog(for date: Date) -> DailyLog {
        if let existing = fetchLog(for: date) {
            return existing
        }
        let log = DailyLog(date: date)
        modelContext.insert(log)
        return log
    }

    @discardableResult
    private func save(mirrorReason: String = "nutrition_store_save") -> Bool {
        do {
            try modelContext.save()
            tursoMirror?.scheduleMirror(reason: mirrorReason)
            changeCount += 1
            return true
        } catch {
            // Keep existing non-throwing write behavior for UI flows.
            changeCount += 1
            return false
        }
    }

    private func scheduleHealthSync(for entry: NutritionEntry) {
        guard isHealthSyncEnabled(), let healthSyncer else { return }
        Task {
            await healthSyncer.syncNutritionEntry(entry, in: modelContext)
        }
    }

    private func scheduleHealthDelete(forEntryID entryID: UUID) {
        guard isHealthSyncEnabled(), let healthSyncer else { return }
        Task {
            await healthSyncer.deleteNutritionSamples(forEntryID: entryID)
        }
    }

    private static func timestamp(on date: Date, preservingTimeFrom timestamp: Date) -> Date {
        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute, .second], from: timestamp)
        return calendar.date(
            bySettingHour: time.hour ?? 0,
            minute: time.minute ?? 0,
            second: time.second ?? 0,
            of: date
        ) ?? date
    }

    private func markHealthKitSyncStaleIfNeeded(_ entry: NutritionEntry) {
        if entry.healthKitLastWriteHash != entry.healthKitWriteHash {
            entry.healthKitSyncStatus = HealthKitSyncStatus.notSynced
            entry.healthKitLastError = nil
        }
    }
}
