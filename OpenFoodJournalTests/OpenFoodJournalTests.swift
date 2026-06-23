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

}
