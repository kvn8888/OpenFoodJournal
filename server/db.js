// OpenFoodJournal — Turso Database Module
// Manages the connection to Turso (libSQL) and runs schema migrations.
// All tables use UUIDs as primary keys to match SwiftData's client-side IDs.
// JSON columns store flexible data (micronutrients, serving mappings).
//
// Environment variables required:
//   TURSO_DATABASE_URL — e.g. libsql://your-db-name.turso.io
//   TURSO_AUTH_TOKEN   — authentication token from Turso dashboard

const { createClient } = require("@libsql/client");

// ── Create Turso Client ───────────────────────────────────────────────
// Falls back to a local SQLite file for development if no URL is set
const db = createClient({
  url: process.env.TURSO_DATABASE_URL || "file:local.db",
  authToken: process.env.TURSO_AUTH_TOKEN,
});

// ── Schema Migration ──────────────────────────────────────────────────
// Runs on server startup. All statements are idempotent (IF NOT EXISTS).
// Adding columns later? Add ALTER TABLE statements at the bottom.

async function runMigrations() {
  console.log("[db] Running schema migrations...");

  // Daily logs — one per calendar day
  // The `date` column stores ISO date strings normalized to midnight (YYYY-MM-DD)
  await db.execute(`
    CREATE TABLE IF NOT EXISTS daily_logs (
      id TEXT PRIMARY KEY,
      date TEXT NOT NULL UNIQUE,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    )
  `);

  // Nutrition entries — individual food items logged to a daily log
  // micronutrients and serving_mappings are JSON strings for flexibility
  await db.execute(`
    CREATE TABLE IF NOT EXISTS nutrition_entries (
      id TEXT PRIMARY KEY,
      daily_log_id TEXT NOT NULL REFERENCES daily_logs(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      brand TEXT,
      meal_type TEXT NOT NULL,
      scan_mode TEXT NOT NULL DEFAULT 'manual',
      confidence REAL,
      calories REAL NOT NULL DEFAULT 0,
      protein REAL NOT NULL DEFAULT 0,
      carbs REAL NOT NULL DEFAULT 0,
      fat REAL NOT NULL DEFAULT 0,
      micronutrients TEXT DEFAULT '{}',
      serving_size TEXT,
      servings_per_container REAL,
      serving_quantity REAL,
      serving_unit TEXT,
      serving_mappings TEXT DEFAULT '[]',
      -- Structured serving dimensions (populated by updated Gemini prompt)
      serving_type TEXT,          -- 'mass' | 'volume' | 'both'
      serving_grams REAL,         -- gram weight of one serving
      serving_ml REAL,            -- mL volume of one serving (null for solid foods)
      timestamp TEXT NOT NULL DEFAULT (datetime('now')),
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    )
  `);

  // Saved foods — the Food Bank (reusable food templates)
  await db.execute(`
    CREATE TABLE IF NOT EXISTS saved_foods (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      brand TEXT,
      calories REAL NOT NULL DEFAULT 0,
      protein REAL NOT NULL DEFAULT 0,
      carbs REAL NOT NULL DEFAULT 0,
      fat REAL NOT NULL DEFAULT 0,
      micronutrients TEXT DEFAULT '{}',
      serving_size TEXT,
      servings_per_container REAL,
      serving_quantity REAL,
      serving_unit TEXT,
      serving_mappings TEXT DEFAULT '[]',
      -- Structured serving dimensions
      serving_type TEXT,
      serving_grams REAL,
      serving_ml REAL,
      scan_mode TEXT DEFAULT 'manual',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    )
  `);

  // Tracked containers — weight-based consumption tracking
  // Nutrition data is snapshotted from the food at creation time
  await db.execute(`
    CREATE TABLE IF NOT EXISTS tracked_containers (
      id TEXT PRIMARY KEY,
      food_name TEXT NOT NULL,
      food_brand TEXT,
      calories_per_serving REAL NOT NULL,
      protein_per_serving REAL NOT NULL,
      carbs_per_serving REAL NOT NULL,
      fat_per_serving REAL NOT NULL,
      micronutrients_per_serving TEXT DEFAULT '{}',
      grams_per_serving REAL NOT NULL,
      start_weight REAL NOT NULL,
      final_weight REAL,
      start_date TEXT NOT NULL,
      completed_date TEXT,
      saved_food_id TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    )
  `);

  // User goals — daily macro targets
  // Single row per user (for now, just one default user)
  await db.execute(`
    CREATE TABLE IF NOT EXISTS user_goals (
      id TEXT PRIMARY KEY DEFAULT 'default',
      calorie_goal REAL NOT NULL DEFAULT 2000,
      protein_goal REAL NOT NULL DEFAULT 150,
      carbs_goal REAL NOT NULL DEFAULT 250,
      fat_goal REAL NOT NULL DEFAULT 65,
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    )
  `);

  // Seed default goals if none exist
  await db.execute(`
    INSERT OR IGNORE INTO user_goals (id) VALUES ('default')
  `);

  // ── Column-Level Migrations ────────────────────────────────────
  // Add columns introduced after the initial schema was deployed.
  // PRAGMA table_info() lets us check existing columns without catching exceptions.
  // Each block only runs the ALTER TABLE if the column is absent, making it safe
  // to re-deploy without touching already-migrated databases.

  // serving_type / serving_grams / serving_ml — added with ServingSize enum refactor
  const entryInfo = await db.execute("PRAGMA table_info(nutrition_entries)");
  const entryColumns = entryInfo.rows.map((r) => r.name);
  if (!entryColumns.includes("serving_type")) {
    await db.execute(
      "ALTER TABLE nutrition_entries ADD COLUMN serving_type TEXT"
    );
    await db.execute(
      "ALTER TABLE nutrition_entries ADD COLUMN serving_grams REAL"
    );
    await db.execute(
      "ALTER TABLE nutrition_entries ADD COLUMN serving_ml REAL"
    );
    console.log(
      "[db] Migrated nutrition_entries: added serving_type, serving_grams, serving_ml"
    );
  }

  const foodInfo = await db.execute("PRAGMA table_info(saved_foods)");
  const foodColumns = foodInfo.rows.map((r) => r.name);
  if (!foodColumns.includes("serving_type")) {
    await db.execute(
      "ALTER TABLE saved_foods ADD COLUMN serving_type TEXT"
    );
    await db.execute(
      "ALTER TABLE saved_foods ADD COLUMN serving_grams REAL"
    );
    await db.execute(
      "ALTER TABLE saved_foods ADD COLUMN serving_ml REAL"
    );
    console.log(
      "[db] Migrated saved_foods: added serving_type, serving_grams, serving_ml"
    );
  }

  console.log("[db] Migrations complete.");
}

module.exports = { db, runMigrations };
