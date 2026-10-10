//
//  OpenFoodJournalTests.swift
//  OpenFoodJournalTests
//
//  Created by Kevin Chen on 3/19/26.
//

import Testing
import Foundation
import SwiftData
@testable import OpenFoodJournal

struct OpenFoodJournalTests {

    @Test func tursoURLNormalization() async throws {
        #expect(TursoMirrorService.normalizedHTTPURLString("libsql://db-org.turso.io") == "https://db-org.turso.io")
        #expect(TursoMirrorService.normalizedHTTPURLString("https://db-org.turso.io") == "https://db-org.turso.io")
        #expect(TursoMirrorService.normalizedHTTPURLString("http://db-org.turso.io") == nil)
        #expect(TursoMirrorService.normalizedHTTPURLString("not a url") == nil)
    }

    @MainActor
    @Test func tursoSQLValueEncodingUsesTypedArgs() throws {
        let statement = TursoSQLStatement(sql: "SELECT ?, ?, ?, ?, ?", args: [
            .null,
            .integer(42),
            .real(3.5),
            .text("milk"),
            .blob(Data([0x01, 0x02]))
        ])

        let data = try JSONEncoder().encode(statement)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let args = try #require(json["args"] as? [[String: Any]])

        #expect(args[0]["type"] as? String == "null")
        #expect(args[1]["type"] as? String == "integer")
        #expect(args[1]["value"] as? String == "42")
        #expect(args[2]["type"] as? String == "float")
        #expect(args[2]["value"] as? Double == 3.5)
        #expect(args[3]["type"] as? String == "text")
        #expect(args[3]["value"] as? String == "milk")
        #expect(args[4]["type"] as? String == "blob")
        #expect(args[4]["base64"] as? String == "AQI=")
    }

    @Test func tursoMigrationStatementsCoverEveryMirrorTable() {
        let statements = TursoSchema.createTableStatements
        let joined = statements.joined(separator: "\n")

        for table in TursoSchema.tables {
            #expect(joined.contains("CREATE TABLE IF NOT EXISTS \(table.name)"))
        }

        #expect(joined.contains("cached_input_token_count INTEGER"))
        #expect(joined.contains("provider TEXT"))
        #expect(joined.contains("accent_theme TEXT"))
        #expect(!joined.contains("ADD COLUMN IF NOT EXISTS"))
    }

    @Test func tursoDiagnosticsUseAnAppendOnlyTableOutsideGenerationMirroring() {
        #expect(TursoSchema.tables.contains(where: { $0.name == "ofj_ai_diagnostic_events" }))
        #expect(!TursoSchema.mirroredTableNames.contains("ofj_ai_diagnostic_events"))
        #expect(TursoSchema.mirroredTableNames.contains("ofj_gemini_cost_accumulators"))
    }

    @Test func aiDiagnosticOutboxIsBoundedExpiresAndAcknowledgesEvents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ofj-ai-diagnostic-outbox-tests-(UUID().uuidString)", directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "outbox.json", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIDiagnosticOutboxStore(
            fileURL: fileURL,
            maximumEvents: 2,
            maximumBytes: 1_000_000,
            maximumAge: 60
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = AIDiagnosticEvent(
            createdAt: now.addingTimeInterval(-61),
            eventType: "assistant_span",
            operation: "expired",
            status: "completed"
        )
        let first = AIDiagnosticEvent(
            createdAt: now.addingTimeInterval(-2),
            eventType: "assistant_span",
            operation: "first",
            status: "completed"
        )
        let second = AIDiagnosticEvent(
            createdAt: now.addingTimeInterval(-1),
            eventType: "assistant_span",
            operation: "second",
            status: "completed"
        )
        let third = AIDiagnosticEvent(
            createdAt: now,
            eventType: "assistant_span",
            operation: "third",
            status: "completed"
        )

        store.append(expired, now: now)
        store.append(first, now: now)
        store.append(second, now: now)
        store.append(third, now: now)

        #expect(store.events(now: now).map(\.id) == [second.id, third.id])
        #expect(store.remove(ids: Set([second.id])) == 1)
        #expect(store.events(now: now).map(\.id) == [third.id])
    }

    @MainActor
    @Test func remoteScanDiagnosticEnvelopeOmitsPromptsResponsesSourcesAndThinking() {
        let log = GeminiScanLog(
            operation: .scan,
            status: .success,
            provider: "gemini",
            userPrompt: "private meal prompt",
            requestPrompt: "private system request",
            responseText: "private provider answer",
            rawResponseJSON: #"{"secret":"raw"}"#,
            modelAttemptsJSON: #"[{"secret":"attempt"}]"#,
            groundingSourceURLs: ["https://private.example/source"],
            groundingSourceTitles: ["Private title"],
            groundingMetadataJSON: #"{"source":"private"}"#,
            errorMessage: "private provider error body",
            responseJSON: #"{"journal":"private"}"#,
            thinkingTrace: ["private reasoning"]
        )

        let event = AIDiagnosticEvent(scanLog: log)
        let payload = event.payloadJSON ?? ""

        #expect(!payload.contains("private meal prompt"))
        #expect(!payload.contains("private system request"))
        #expect(!payload.contains("private provider answer"))
        #expect(!payload.contains("private.example"))
        #expect(!payload.contains("private reasoning"))
        #expect(!payload.contains("secret"))
        #expect(!payload.contains("journal"))
        #expect(event.errorMessage == nil)
    }

    @MainActor
    @Test func tursoDiagnosticFlushUsesAppendOnlyUpsertAndAcknowledgesOutbox() async throws {
        let harness = try ChatTestHarness()
        let suiteName = "ofj-turso-diagnostic-tests-(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: TursoMirrorService.enabledKey)
        defaults.set(true, forKey: TursoMirrorService.includeDiagnosticsKey)

        let directory = FileManager.default.temporaryDirectory
            .appending(path: suiteName, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var requestBodies: [String] = []
        StubChatURLProtocol.handler = { request in
            requestBodies.append(String(
                data: StubChatURLProtocol.bodyData(for: request) ?? Data(),
                encoding: .utf8
            ) ?? "")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-turso-token")
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = #"{"results":[{"response":{"result":{"cols":[],"rows":[]}}},{"response":{}}]}"#
                .data(using: .utf8)!
            return (response, data)
        }
        defer { StubChatURLProtocol.handler = nil }

        let service = TursoMirrorService(
            modelContext: harness.context,
            session: StubChatURLProtocol.session(),
            defaults: defaults,
            diagnosticOutboxURL: directory.appending(path: "outbox.json"),
            networkAccess: .unitTests,
            credentialProvider: {
                ("https://test-diagnostics.turso.io", "test-turso-token")
            }
        )
        let event = AIDiagnosticEvent(
            eventType: "assistant_span",
            operation: "first_provider_event",
            status: "completed",
            providerID: "azureOpenAI",
            baseModelID: "gpt-5.6-terra",
            deploymentID: "terra-deployment",
            runID: UUID(),
            providerRequestID: "request-123",
            durationMs: 321
        )

        service.recordDiagnostic(event)
        #expect(service.pendingDiagnosticCount == 1)
        #expect(await service.flushDiagnosticOutbox())
        #expect(service.pendingDiagnosticCount == 0)
        #expect(requestBodies.contains(where: {
            $0.contains("INSERT INTO ofj_ai_diagnostic_events")
                && $0.contains(event.id.uuidString)
        }))
        #expect(requestBodies.contains(where: {
            $0.contains("DELETE FROM ofj_ai_diagnostic_events WHERE expires_at <= ?")
        }))
    }

    #if DEBUG
    @MainActor
    @Test func developerBuildUsesIsolatedCloudKitAndDisablesHealthKit() {
        #expect(MacrosApp.cloudKitContainerIdentifier == "iCloud.k3vnc.OpenFoodJournal.dev")
        #expect(!HealthKitService().isAvailable)
    }

    @MainActor
    @Test func developerBuildBlocksTursoWithoutReadingCredentials() async throws {
        let harness = try ChatTestHarness()
        let suiteName = "ofj-turso-debug-isolation-tests-(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: TursoMirrorService.enabledKey)
        defaults.set(true, forKey: TursoMirrorService.includeDiagnosticsKey)

        let directory = FileManager.default.temporaryDirectory
            .appending(path: suiteName, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var credentialReadCount = 0
        var requestCount = 0
        StubChatURLProtocol.handler = { request in
            requestCount += 1
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        defer { StubChatURLProtocol.handler = nil }

        let service = TursoMirrorService(
            modelContext: harness.context,
            session: StubChatURLProtocol.session(),
            defaults: defaults,
            diagnosticOutboxURL: directory.appending(path: "outbox.json"),
            credentialProvider: {
                credentialReadCount += 1
                return ("https://should-not-run.turso.io", "should-not-run")
            }
        )

        #expect(!service.isEnabled)
        service.recordDiagnostic(AIDiagnosticEvent(
            eventType: "assistant_span",
            operation: "debug_isolation",
            status: "completed"
        ))
        #expect(service.pendingDiagnosticCount == 0)
        #expect(!(await service.flushDiagnosticOutbox()))
        await service.clearAIDiagnostics()

        do {
            try await service.testConnection()
            Issue.record("Debug testConnection unexpectedly reached Turso")
        } catch TursoMirrorError.disabledInDeveloperBuild {
            // Expected: the build policy rejects access before credentials.
        } catch {
            Issue.record("Unexpected Debug Turso error: \(error)")
        }

        #expect(credentialReadCount == 0)
        #expect(requestCount == 0)
    }
    #endif

    @Test func tursoUpsertStatementUsesPlaceholders() {
        let row = TursoMirrorRow(table: "ofj_app_settings", columns: [
            "id": .text("default"),
            "use_gemini_pro": .bool(true),
            "mirror_generation": .text("generation")
        ])

        let statement = TursoMirrorService.upsertStatement(for: row)

        #expect(statement.sql.contains("INSERT INTO ofj_app_settings"))
        #expect(statement.sql.contains("ON CONFLICT(id) DO UPDATE"))
        #expect(statement.sql.contains("VALUES (?, ?, ?)"))
        #expect(statement.args.count == 3)
    }

    @Test func mealTimeSettingsDefaultBoundariesMatchRequestedRanges() {
        #expect(MealTimeSettings.mealType(forMinuteOfDay: 1 * 60 + 59) == .dinner)
        #expect(MealTimeSettings.mealType(forMinuteOfDay: 2 * 60) == .breakfast)
        #expect(MealTimeSettings.mealType(forMinuteOfDay: 11 * 60 + 59) == .breakfast)
        #expect(MealTimeSettings.mealType(forMinuteOfDay: 12 * 60) == .lunch)
        #expect(MealTimeSettings.mealType(forMinuteOfDay: 17 * 60 + 59) == .lunch)
        #expect(MealTimeSettings.mealType(forMinuteOfDay: 18 * 60) == .dinner)
        #expect(MealTimeSettings.mealType(forMinuteOfDay: 23 * 60 + 59) == .dinner)
    }

    @MainActor
    @Test func appSettingsRecordDecodesOlderBackupsWithDefaultMealSchedule() throws {
        let json = """
        {
            "useProModel": true,
            "offContributeEnabled": false
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(AppSettingsRecord.self, from: json)

        #expect(record.useProModel)
        #expect(!record.offContributeEnabled)
        #expect(record.accentTheme == OFJAccentTheme.defaultTheme.rawValue)
        #expect(record.breakfastStartMinutes == MealScheduleDefaults.breakfastStartMinutes)
        #expect(record.lunchStartMinutes == MealScheduleDefaults.lunchStartMinutes)
        #expect(record.dinnerStartMinutes == MealScheduleDefaults.dinnerStartMinutes)
        #expect(record.assistantProvider == AIProviderSettings.defaultProvider.rawValue)
        #expect(record.azureEndpoint.isEmpty)
        #expect(record.azureSolDeployment.isEmpty)
        #expect(record.azureTerraDeployment.isEmpty)
        #expect(record.azureDefaultModel == AIProviderSettings.defaultAzureModel.rawValue)
        #expect(record.chatContextBudget == ChatContextBudget.balanced.rawValue)
        #expect(record.assistantResearchProvider == AssistantResearchProvider.modelProvider.rawValue)
        #expect(record.tavilySearchDepth == TavilySearchDepth.fast.rawValue)
        #expect(record.parallelSearchMode == ParallelSearchMode.basic.rawValue)
        #expect(record.openAIFastModel == AIProviderSettings.defaultOpenAIFastModel)
        #expect(record.openAISmartModel == AIProviderSettings.defaultOpenAISmartModel)
        #expect(record.anthropicFastModel == AIProviderSettings.defaultAnthropicFastModel)
        #expect(record.anthropicSmartModel == AIProviderSettings.defaultAnthropicSmartModel)
        #expect(record.museSparkModel == AIProviderSettings.defaultMuseSparkModel)
        #expect(record.pinnedMicronutrientIDs.isEmpty)
        #expect(record.micronutrientGoalOverrides.isEmpty)
    }

    @MainActor
    @Test func appSettingsRecordRoundTripsAccentTheme() throws {
        let original = AppSettingsRecord(
            accentTheme: OFJAccentTheme.harvestOrange.rawValue,
            useProModel: false,
            offContributeEnabled: false
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettingsRecord.self, from: data)

        #expect(decoded.accentTheme == OFJAccentTheme.harvestOrange.rawValue)
    }

    @MainActor
    @Test func appSettingsRecordFallsBackFromUnknownAccentTheme() throws {
        let data = Data(#"{"accentTheme":"future-theme"}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettingsRecord.self, from: data)

        #expect(decoded.accentTheme == OFJAccentTheme.defaultTheme.rawValue)
    }

    @Test func chatToolRecordPreservesGeminiReplayMetadata() throws {
        let record = ChatToolRecord(
            callID: "call_123",
            thoughtSignature: "opaque-signature==",
            modelTurnID: "model-turn-1",
            modelTurnIndex: 0,
            name: "read_journal",
            argsJSON: #"{"date":"2026-07-20"}"#,
            resultJSON: #"{"entries":[]}"#,
            status: .completed,
            summary: "Read journal"
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ChatToolRecord.self, from: data)

        #expect(decoded.callID == "call_123")
        #expect(decoded.thoughtSignature == "opaque-signature==")
        #expect(decoded.modelTurnID == "model-turn-1")
        #expect(decoded.modelTurnIndex == 0)
    }

    @Test func chatToolRecordDecodesLegacyPayloadWithoutGeminiReplayMetadata() throws {
        let json = #"""
        {
            "callID": "legacy-call",
            "name": "read_journal",
            "argsJSON": "{}",
            "resultJSON": "{}",
            "status": "completed",
            "summary": "Read journal"
        }
        """#.data(using: .utf8)!

        let record = try JSONDecoder().decode(ChatToolRecord.self, from: json)

        #expect(record.callID == "legacy-call")
        #expect(record.thoughtSignature == nil)
        #expect(record.modelTurnID == nil)
        #expect(record.modelTurnIndex == nil)
        #expect(record.providerContinuations == nil)
        #expect(record.providerID == nil)
        #expect(record.modelID == nil)
        #expect(record.providerRequestID == nil)
        #expect(record.sourceArtifactIDs == nil)
    }

    @Test func foodEmojiExtractionReturnsFirstEmojiOnly() throws {
        #expect(ScanService.extractFoodEmoji(from: "🍎") == "🍎")
        #expect(ScanService.extractFoodEmoji(from: "  🍽️  ") == "🍽️")
        #expect(ScanService.extractFoodEmoji(from: "🍣 sushi") == "🍣")
        #expect(ScanService.extractFoodEmoji(from: "apple") == nil)
    }

    @Test func savedFoodRecordDecodesOlderBackupsWithoutEmoji() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000020",
            "name": "Milk",
            "brand": "Dairy",
            "createdAt": "2026-06-27T12:00:00Z",
            "calories": 120,
            "protein": 8,
            "carbs": 12,
            "fat": 5,
            "micronutrients": {},
            "servingSize": "1 cup",
            "servingsPerContainer": null,
            "serving": null,
            "servingQuantity": 1,
            "servingUnit": "cup",
            "servingMappings": [],
            "originalScanMode": "manual",
            "lastUsedAt": "2026-06-27T12:00:00Z",
            "kind": "single",
            "compositeIngredients": [],
            "calculatorIngredients": []
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(SavedFoodRecord.self, from: json)

        #expect(record.emoji == nil)
        #expect(record.makeModel().emoji == nil)
        #expect(!record.isOnShelf)
        #expect(!record.makeModel().isOnShelf)
    }

    @Test func micronutrientValueDecodesBareNumbersWithKnownUnits() throws {
        let json = """
        {
            "sodium": 1007.4,
            "fiber": 12.5,
            "sugar": 8.25,
            "added_sugars": 3.5,
            "mystery_nutrient": 2
        }
        """.data(using: .utf8)!

        let values = try JSONDecoder().decode([String: MicronutrientValue].self, from: json)

        #expect(values["sodium"]?.value == 1007.4)
        #expect(values["sodium"]?.unit == "mg")
        #expect(values["fiber"]?.value == 12.5)
        #expect(values["fiber"]?.unit == "g")
        #expect(values["sugar"]?.value == 8.25)
        #expect(values["sugar"]?.unit == "g")
        #expect(values["added_sugars"]?.value == 3.5)
        #expect(values["added_sugars"]?.unit == "g")
        #expect(values["mystery_nutrient"]?.value == 2)
        #expect(values["mystery_nutrient"]?.unit == "")
    }

    @Test func micronutrientValueDecodesObjectShape() throws {
        let json = """
        {
            "sodium": {
                "value": 1007.4,
                "unit": "mg"
            },
            "fiber": {
                "value": 12.5,
                "unit": "g"
            }
        }
        """.data(using: .utf8)!

        let values = try JSONDecoder().decode([String: MicronutrientValue].self, from: json)

        #expect(values["sodium"]?.value == 1007.4)
        #expect(values["sodium"]?.unit == "mg")
        #expect(values["fiber"]?.value == 12.5)
        #expect(values["fiber"]?.unit == "g")
    }

    @Test func micronutrientLookupBridgesCanonicalAndDisplayKeys() throws {
        let canonical: [String: MicronutrientValue] = [
            "sodium": MicronutrientValue(value: 980, unit: "mg"),
            "fiber": MicronutrientValue(value: 8, unit: "g"),
            "sugar": MicronutrientValue(value: 12, unit: "g"),
            "saturated_fat": MicronutrientValue(value: 6, unit: "g")
        ]

        #expect(KnownMicronutrients.value(in: canonical, forID: "sodium")?.value == 980)
        #expect(KnownMicronutrients.value(in: canonical, forID: "fiber")?.value == 8)
        #expect(KnownMicronutrients.value(in: canonical, forID: "sugar", aliases: ["Sugar"])?.value == 12)
        #expect(KnownMicronutrients.value(in: canonical, forID: "saturated_fat")?.value == 6)

        let display: [String: MicronutrientValue] = [
            "Sodium": MicronutrientValue(value: 1360, unit: "mg"),
            "Fiber": MicronutrientValue(value: 2, unit: "g"),
            "Sugar": MicronutrientValue(value: 10, unit: "g"),
            "Saturated Fat": MicronutrientValue(value: 14, unit: "g")
        ]

        #expect(KnownMicronutrients.value(in: display, forID: "sodium")?.value == 1360)
        #expect(KnownMicronutrients.value(in: display, forID: "fiber")?.value == 2)
        #expect(KnownMicronutrients.value(in: display, forID: "sugar", aliases: ["Sugar"])?.value == 10)
        #expect(KnownMicronutrients.value(in: display, forID: "saturated_fat")?.value == 14)
    }

    @MainActor
    @Test func healthKitDefinitionsIncludeExpandedDietaryNutrients() {
        let keys = Set(HealthKitService.healthKitSampleDefinitionKeys)
        let expectedKeys = [
            "dietaryBiotin",
            "dietaryCaffeine",
            "dietaryChloride",
            "dietaryChromium",
            "dietaryCopper",
            "dietaryFatMonounsaturated",
            "dietaryFatPolyunsaturated",
            "dietaryFolate",
            "dietaryIodine",
            "dietaryMagnesium",
            "dietaryManganese",
            "dietaryMolybdenum",
            "dietaryNiacin",
            "dietaryPantothenicAcid",
            "dietaryPhosphorus",
            "dietaryRiboflavin",
            "dietarySelenium",
            "dietaryThiamin",
            "dietaryVitaminB6",
            "dietaryVitaminB12",
            "dietaryVitaminD",
            "dietaryVitaminE",
            "dietaryVitaminK",
            "dietaryWater",
            "dietaryZinc"
        ]

        for key in expectedKeys {
            #expect(keys.contains(key), "\(key) should be writable to HealthKit")
        }

        #expect(!keys.contains("dietaryAddedSugars"))
        #expect(!keys.contains("dietaryTransFat"))
        #expect(HealthKitService.unsupportedNutritionExportKeys == ["added_sugars", "trans_fat"])
    }

    @MainActor
    @Test func healthKitSampleDefinitionsReadCanonicalAndDisplayKeys() {
        let cases: [(sampleKey: String, canonical: String, display: String, value: Double, unit: String)] = [
            ("dietaryBiotin", "biotin", "Biotin", 30, "mcg"),
            ("dietaryCaffeine", "caffeine", "Caffeine", 95, "mg"),
            ("dietaryChloride", "chloride", "Chloride", 230, "mg"),
            ("dietaryChromium", "chromium", "Chromium", 35, "mcg"),
            ("dietaryCopper", "copper", "Copper", 0.9, "mg"),
            ("dietaryFatMonounsaturated", "monounsaturated_fat", "Monounsaturated Fat", 7, "g"),
            ("dietaryFatPolyunsaturated", "polyunsaturated_fat", "Polyunsaturated Fat", 4, "g"),
            ("dietaryFolate", "folate", "Folate", 400, "mcg"),
            ("dietaryIodine", "iodine", "Iodine", 150, "mcg"),
            ("dietaryMagnesium", "magnesium", "Magnesium", 420, "mg"),
            ("dietaryManganese", "manganese", "Manganese", 2.3, "mg"),
            ("dietaryMolybdenum", "molybdenum", "Molybdenum", 45, "mcg"),
            ("dietaryNiacin", "niacin", "Niacin", 16, "mg"),
            ("dietaryPantothenicAcid", "pantothenic_acid", "Pantothenic Acid", 5, "mg"),
            ("dietaryPhosphorus", "phosphorus", "Phosphorus", 1250, "mg"),
            ("dietaryRiboflavin", "riboflavin", "Riboflavin", 1.3, "mg"),
            ("dietarySelenium", "selenium", "Selenium", 55, "mcg"),
            ("dietaryThiamin", "thiamin", "Thiamine", 1.2, "mg"),
            ("dietaryVitaminB6", "vitamin_b6", "Vitamin B6", 1.7, "mg"),
            ("dietaryVitaminB12", "vitamin_b12", "Vitamin B12", 2.4, "mcg"),
            ("dietaryVitaminD", "vitamin_d", "Vitamin D", 20, "mcg"),
            ("dietaryVitaminE", "vitamin_e", "Vitamin E", 15, "mg"),
            ("dietaryVitaminK", "vitamin_k", "Vitamin K", 120, "mcg"),
            ("dietaryWater", "water", "Water", 500, "mL"),
            ("dietaryZinc", "zinc", "Zinc", 11, "mg")
        ]

        let canonicalEntry = nutritionEntry(micronutrients: Dictionary(
            uniqueKeysWithValues: cases.map {
                ($0.canonical, MicronutrientValue(value: $0.value, unit: $0.unit))
            }
        ))
        let displayEntry = nutritionEntry(micronutrients: Dictionary(
            uniqueKeysWithValues: cases.map {
                ($0.display, MicronutrientValue(value: $0.value, unit: $0.unit))
            }
        ))

        for testCase in cases {
            #expect(
                HealthKitService.healthKitSampleValue(for: canonicalEntry, sampleKey: testCase.sampleKey) == testCase.value,
                "\(testCase.sampleKey) should read \(testCase.canonical)"
            )
            #expect(
                HealthKitService.healthKitSampleValue(for: displayEntry, sampleKey: testCase.sampleKey) == testCase.value,
                "\(testCase.sampleKey) should read \(testCase.display)"
            )
        }
    }

    @Test func healthKitWriteHashIncludesExportSchemaVersion() {
        let entry = nutritionEntry(micronutrients: [
            "copper": MicronutrientValue(value: 0.9, unit: "mg")
        ])

        #expect(entry.healthKitWriteHash.hasPrefix("healthkit-dietary-export-v2|"))
    }

    @Test func foodBankBrandOptionsTrimAndCountBrands() throws {
        let foods = [
            savedFood(name: "Milk", brand: " Wegmans "),
            savedFood(name: "Yogurt", brand: "Wegmans"),
            savedFood(name: "Rice", brand: "Chipotle"),
            savedFood(name: "Apple", brand: nil),
            savedFood(name: "Banana", brand: " ")
        ]

        let options = FoodBankBrandCatalog.options(in: foods, includeUnbranded: true)

        #expect(options.first?.name == "Unbranded")
        #expect(options.first?.count == 2)
        #expect(options.contains { $0.name == "Chipotle" && $0.count == 1 })
        #expect(options.contains { $0.name == "Wegmans" && $0.count == 2 })
    }

    @Test func foodBankBrandFilterMatchesExactTrimmedBrandAndUnbranded() throws {
        let wegmans = savedFood(name: "Milk", brand: " Wegmans ")
        let lower = savedFood(name: "Yogurt", brand: "wegmans")
        let unbranded = savedFood(name: "Apple", brand: "")

        #expect(FoodBankBrandCatalog.matches(wegmans, filter: .brand("Wegmans")))
        #expect(!FoodBankBrandCatalog.matches(lower, filter: .brand("Wegmans")))
        #expect(FoodBankBrandCatalog.matches(unbranded, filter: .unbranded))
        #expect(FoodBankBrandCatalog.matches(lower, filter: .all))
    }

    @Test func foodBankBrandSortGroupsNamedBrandsBeforeUnbranded() throws {
        let foods = [
            savedFood(name: "Banana", brand: nil),
            savedFood(name: "Rice", brand: "Chipotle"),
            savedFood(name: "Milk", brand: "Wegmans"),
            savedFood(name: "Beans", brand: "Chipotle")
        ]

        let sorted = FoodBankBrandCatalog.sortByBrand(foods)

        #expect(sorted.map(\.name) == ["Beans", "Rice", "Milk", "Banana"])
    }

    @Test func foodBankBrandConsolidationUpdatesOnlyExactSourceBrand() throws {
        let foods = [
            savedFood(name: "Milk", brand: "Wegman's"),
            savedFood(name: "Yogurt", brand: "Wegman's"),
            savedFood(name: "Cereal", brand: "wegmans"),
            savedFood(name: "Rice", brand: "Chipotle")
        ]

        let updated = FoodBankBrandCatalog.consolidate(
            sourceBrand: "Wegman's",
            targetBrand: "Wegmans",
            in: foods
        )

        #expect(updated == 2)
        #expect(foods[0].brand == "Wegmans")
        #expect(foods[1].brand == "Wegmans")
        #expect(foods[2].brand == "wegmans")
        #expect(foods[3].brand == "Chipotle")
    }

    private func savedFood(name: String, brand: String?) -> SavedFood {
        SavedFood(
            name: name,
            brand: brand,
            calories: 100,
            protein: 5,
            carbs: 10,
            fat: 3
        )
    }

    private func nutritionEntry(micronutrients: [String: MicronutrientValue]) -> NutritionEntry {
        NutritionEntry(
            name: "Test Food",
            calories: 100,
            protein: 5,
            carbs: 10,
            fat: 3,
            micronutrients: micronutrients
        )
    }

}
