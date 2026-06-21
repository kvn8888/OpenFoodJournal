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
        let args = try #require(json["args"] as? [[String: String]])

        #expect(args[0]["type"] == "null")
        #expect(args[1]["type"] == "integer")
        #expect(args[1]["value"] == "42")
        #expect(args[2]["type"] == "float")
        #expect(args[2]["value"] == "3.5")
        #expect(args[3]["type"] == "text")
        #expect(args[3]["value"] == "milk")
        #expect(args[4]["type"] == "blob")
        #expect(args[4]["base64"] == "AQI=")
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

}
