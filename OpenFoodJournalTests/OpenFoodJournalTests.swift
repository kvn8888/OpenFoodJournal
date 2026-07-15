//
//  OpenFoodJournalTests.swift
//  OpenFoodJournalTests
//
//  Created by Kevin Chen on 3/19/26.
//

import Testing
import Foundation
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

        #expect(!joined.contains("ADD COLUMN IF NOT EXISTS"))
    }

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
        #expect(record.breakfastStartMinutes == MealScheduleDefaults.breakfastStartMinutes)
        #expect(record.lunchStartMinutes == MealScheduleDefaults.lunchStartMinutes)
        #expect(record.dinnerStartMinutes == MealScheduleDefaults.dinnerStartMinutes)
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
