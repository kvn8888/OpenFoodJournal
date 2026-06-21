# Building an Optional Turso Mirror Without Making It the Source of Truth

OpenFoodJournal had already moved to SwiftData plus CloudKit as the real app database. The new request was to bring Turso back, but only as an optional external mirror that a user or coding agent can inspect with SQL. That changed the problem from "sync data" to "publish a debuggable copy without letting it affect local app behavior."

## The Starting Point

The app already had a clean local-first architecture:

- SwiftData models store the actual journal, food bank, containers, preferences, Gemini logs, and cost totals.
- CloudKit syncs that SwiftData store through Apple's private database.
- Apple Health is a derived export target.
- Gemini calls are direct BYOK requests, with the API key in Keychain.

The thing I wanted to avoid was reintroducing the old mental model where Turso looked like an app backend. If Turso can fail, be stale, or be manually inspected, it cannot also be the source of truth. The correct version of the feature is push-only, best-effort, and non-blocking.

## The Plan I Implemented

The implementation followed this plan:

- Add Settings -> Data -> Turso Integration.
- Store Turso secrets in Keychain:
  - `turso-database-url`
  - `turso-auth-token`
- Store non-secret mirror state in app settings:
  - `turso.enabled`
  - `turso.includeDiagnostics`
  - `turso.lastSyncAt`
  - `turso.lastError`
  - `turso.lastRowCount`
- Accept both `libsql://...` and `https://...`, normalizing `libsql://` into the HTTPS endpoint used by Turso SQL-over-HTTP.
- Use Turso SQL-over-HTTP directly through `/v2/pipeline`, not the Swift SDK and not a proxy server.
- Keep the schema namespaced with `ofj_*` tables so it does not collide with old server tables.
- Mirror normalized rows, using JSON columns for complex Swift value fields such as micronutrients, serving mappings, composite ingredients, calculator groups, calculator presets, and Gemini thinking traces.
- Include Gemini logs and cost accumulator rows by default, while excluding API keys, Turso tokens, raw image bytes, raw photos, and HealthKit authorization tokens.
- Use `CREATE TABLE IF NOT EXISTS` plus `PRAGMA table_info(table)` for additive migrations. SQLite/libSQL does not support `ALTER TABLE ADD COLUMN IF NOT EXISTS`, so the missing-column check has to be explicit.
- Use a `mirror_generation` per run: upsert current rows for a table, then prune older generations for that table after its batch succeeds.
- Add an agent utility script at `.agents/skills/openfoodjournal/scripts/turso_debug.py` with read-only commands for summary, day lookup, entry lookup, food search, pending HealthKit rows, Gemini failures, and guarded raw SQL.
- Wire mirror scheduling after normal local writes, app launch, and foreground events.
- Keep all mirror failures non-blocking.

The important design line was this: SwiftData plus iCloud own truth; Turso owns observability.

## Step 1: Choosing SQL-over-HTTP Over Another Dependency

Turso has a Swift SDK, but it is still marked technical preview. The app currently has no package dependencies, so adding a preview database SDK would increase build and maintenance surface area for something that only needs HTTP requests.

I used Turso's SQL-over-HTTP API instead. The request shape is simple: send a pipeline of SQL statements with typed arguments.

```swift
enum TursoSQLValue: Encodable, Equatable, Sendable {
    case null
    case integer(Int)
    case real(Double)
    case text(String)
    case blob(Data)
}
```

The slightly non-obvious part is that integer and float values are encoded as strings inside typed argument objects. That keeps the Swift encoder from making precision choices on behalf of the database protocol.

I also normalized database URLs in one pure helper:

```swift
nonisolated static func normalizedHTTPURLString(_ input: String) -> String? {
    if trimmed.lowercased().hasPrefix("libsql://") {
        normalized = "https://" + String(trimmed.dropFirst("libsql://".count))
    } else {
        normalized = trimmed
    }
    ...
}
```

That lets the Settings UI accept the URL a user naturally copies from Turso, while the service always stores the actual HTTPS endpoint it needs.

## Step 2: Mirroring With Generations Instead of Diffs

I chose a full mirror with `mirror_generation` instead of incremental diffs. The current app data size is small, and a full mirror is much easier to reason about than tombstones, conflict resolution, and partial update state.

Each mirror run gets a generation UUID. For each table:

1. Build all current rows from SwiftData.
2. Upsert rows with that generation.
3. Delete rows in that table whose generation is older.

The pruning happens per table after that table succeeds. That matters because it avoids deleting old rows for a table that failed halfway through its current batch.

```swift
private func mirror(
    rows: [TursoMirrorRow],
    in table: String,
    generation: String,
    credentials: (url: URL, token: String)
) async throws {
    let upserts = rows.map(Self.upsertStatement(for:))
    try await execute(upserts, credentials: credentials)
    try await execute(
        [TursoSQLStatement(sql: "DELETE FROM \(table) WHERE mirror_generation != ?", args: [.text(generation)])],
        credentials: credentials
    )
}
```

This is not the most efficient sync algorithm. It is the most defensible first version because it makes "what should be in Turso?" answerable: whatever SwiftData currently contains.

## Step 3: Settings UI as an Operations Panel

The Settings view needed to do more than hold a toggle. Turso is an external integration, so the user needs a small operations panel:

- Save credentials.
- Test connection.
- Run migrations.
- Sync now.
- Remove credentials.
- See enabled state, last successful mirror, last error, and mirrored row count.

The view stores secrets only through `KeychainService`, while the observable status fields use app storage.

```swift
static let tursoDatabaseURLAccount = "turso-database-url"
static let tursoAuthTokenAccount = "turso-auth-token"
```

`Sync Now` is disabled unless credentials exist and mirroring is enabled. I tightened that after the first pass because running migrations without a mirror looked technically possible but was confusing as a user action.

## Step 4: Wiring Writes Without Making Writes Depend on Turso

The app has two kinds of local writes:

- Centralized writes through `NutritionStore`.
- Direct SwiftData saves in view flows like Food Bank editing, containers, calculators, Gemini diagnostics, and HealthKit metadata.

For `NutritionStore`, I changed the private save helper so successful local saves schedule a debounced mirror:

```swift
private func save() {
    do {
        try modelContext.save()
        tursoMirror?.scheduleMirror(reason: "nutrition_store_save")
    } catch {
        // Keep existing non-throwing write behavior for UI flows.
    }
    changeCount += 1
}
```

The important detail is that scheduling the mirror happens after the local save succeeds, and the mirror itself is asynchronous and optional. If Turso is down, the app still logs food, syncs iCloud, and writes Apple Health metadata as before.

I also added targeted `scheduleMirror(reason:)` calls in the direct-save paths so Turso reflects:

- Gemini scan/search logs.
- Gemini cost resets.
- HealthKit sync state.
- Food Bank archive/restore/edit/delete.
- Container creation/deletion.
- Composite foods.
- Nutrition calculators and presets.

## The Gotcha: Tests Exposed Actor Isolation

The app build passed, but `build-for-testing` caught an actor-isolation issue. Because `TursoMirrorService` is `@MainActor`, even pure static helpers were treated as main-actor isolated in tests:

```text
main actor-isolated static method 'normalizedHTTPURLString'
cannot be called from outside of the actor
```

The root cause was not the test. The URL normalizer and upsert builder are pure functions, so they should not require the main actor at all. I marked those helpers `nonisolated` and made the small value types `Sendable`.

That was a good compiler catch. It kept the runtime service on the main actor, where it touches SwiftData and app state, while allowing pure encoding/SQL helpers to be tested without pretending they need UI isolation.

## Step 5: Agent Debugging as a First-Class Use Case

The user specifically wanted Turso because an LLM coding agent can inspect SQL data more easily than opaque device state. I added:

```text
.agents/skills/openfoodjournal/scripts/turso_debug.py
```

The script uses only Python standard library modules and accepts credentials through `TURSO_DATABASE_URL` / `TURSO_AUTH_TOKEN` or `--url` / `--token`.

It is read-only by default. `raw-sql` only allows `SELECT` or `WITH` unless `--allow-write` is explicitly passed. That guard matters because a debugging tool should not casually mutate the user's mirror.

The most useful commands are:

- `summary`
- `day YYYY-MM-DD`
- `entry UUID`
- `food-search TEXT`
- `healthkit-pending`
- `gemini-failures --days 30`
- `raw-sql "SELECT ..."`

This turns Turso into a practical inspection surface instead of just another backup-looking database.

## What Shipped

The implementation added:

- `TursoMirrorService`
- `TursoIntegrationSettingsView`
- Keychain accounts for Turso URL/token
- `SettingsView` entry point under Data
- App/service injection through `OpenFoodJournalApp`
- Debounced mirror scheduling after relevant write paths
- Namespaced `ofj_*` mirror tables
- Gemini diagnostics and cost accumulator mirroring
- Privacy copy updates in Settings/README/disclaimer docs
- Turso unit tests for URL normalization, typed args, migration statement coverage, and upsert construction
- Agent script for SQL inspection
- Project skill updates so future agents know the current architecture

## What I Could Not Fully Validate

I did not run against a live Turso database because no Turso URL/token were provided in the session.

What I did validate:

```bash
.agents/skills/openfoodjournal/scripts/turso_debug.py --help
xcodebuild -quiet -project OpenFoodJournal.xcodeproj -scheme OpenFoodJournal -destination generic/platform=iOS -derivedDataPath /private/tmp/OpenFoodJournalDerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -project OpenFoodJournal.xcodeproj -scheme OpenFoodJournal -destination generic/platform=iOS -derivedDataPath /private/tmp/OpenFoodJournalDerivedData CODE_SIGNING_ALLOWED=NO build-for-testing
```

The missing validation is the real end-to-end Turso path:

1. Save a real Turso URL/token.
2. Test `/health`.
3. Run migrations.
4. Sync now.
5. Query with `turso_debug.py summary`.
6. Log/edit/delete a food and confirm the mirrored tables update.
7. Run a Gemini scan/search and confirm diagnostics mirror when enabled.

## What's Next

The obvious next improvement is a manual live Turso smoke test with a disposable database. After that, I would watch mirror payload size. If the user eventually has thousands of entries and many scan logs, the full mirror may still be fine, but that is when an incremental/tombstone design becomes worth considering.

I would also consider surfacing the latest sync run details in Settings, not just row count and last error. The `ofj_sync_runs` table already stores the data; the UI could eventually show which table failed.

The right v1 is boring on purpose: local data stays local-first, CloudKit keeps syncing devices, and Turso is just a window into the data when debugging needs SQL.
