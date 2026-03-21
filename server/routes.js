// OpenFoodJournal — REST API Routes for Turso
// Full CRUD for all entities: daily_logs, nutrition_entries, saved_foods,
// tracked_containers, and user_goals.
//
// All endpoints return JSON. Errors return { error: "message" }.
// IDs are UUIDs generated client-side (iOS) or server-side (UUID v4).
//
// Routes are mounted at /api/* in index.js

const express = require("express");
const crypto = require("crypto");
const { db } = require("./db");

const router = express.Router();

// ── Helper: generate UUID if client doesn't provide one ───────────────
function uuid() {
  return crypto.randomUUID();
}

// ── Helper: current ISO timestamp ─────────────────────────────────────
function now() {
  return new Date().toISOString();
}

// ═══════════════════════════════════════════════════════════════════════
// DAILY LOGS
// ═══════════════════════════════════════════════════════════════════════

// GET /api/logs — List daily logs, optionally filtered by date range
// Query params: ?from=YYYY-MM-DD&to=YYYY-MM-DD
router.get("/logs", async (req, res) => {
  try {
    const { from, to } = req.query;

    let result;
    if (from && to) {
      result = await db.execute({
        sql: "SELECT * FROM daily_logs WHERE date >= ? AND date <= ? ORDER BY date DESC",
        args: [from, to],
      });
    } else {
      result = await db.execute(
        "SELECT * FROM daily_logs ORDER BY date DESC LIMIT 90"
      );
    }

    res.json(result.rows);
  } catch (err) {
    console.error("[api] GET /logs error:", err);
    res.status(500).json({ error: err.message });
  }
});

// GET /api/logs/:date — Get a single daily log by date (YYYY-MM-DD)
// Returns the log with all its entries embedded
router.get("/logs/:date", async (req, res) => {
  try {
    const logResult = await db.execute({
      sql: "SELECT * FROM daily_logs WHERE date = ?",
      args: [req.params.date],
    });

    if (logResult.rows.length === 0) {
      return res.status(404).json({ error: "No log found for this date" });
    }

    const log = logResult.rows[0];

    // Fetch all entries for this log
    const entriesResult = await db.execute({
      sql: "SELECT * FROM nutrition_entries WHERE daily_log_id = ? ORDER BY timestamp ASC",
      args: [log.id],
    });

    // Parse JSON fields in entries
    const entries = entriesResult.rows.map(parseEntryRow);

    res.json({ ...log, entries });
  } catch (err) {
    console.error("[api] GET /logs/:date error:", err);
    res.status(500).json({ error: err.message });
  }
});

// DELETE /api/logs/:id — Delete a daily log and all its entries (cascade)
router.delete("/logs/:id", async (req, res) => {
  try {
    await db.execute({
      sql: "DELETE FROM daily_logs WHERE id = ?",
      args: [req.params.id],
    });
    res.json({ deleted: true });
  } catch (err) {
    console.error("[api] DELETE /logs/:id error:", err);
    res.status(500).json({ error: err.message });
  }
});

// ═══════════════════════════════════════════════════════════════════════
// NUTRITION ENTRIES
// ═══════════════════════════════════════════════════════════════════════

// POST /api/entries — Create a new nutrition entry
// Body: { date, name, meal_type, calories, protein, carbs, fat, ... }
// If no daily_log exists for the given date, one is created automatically
router.post("/entries", async (req, res) => {
  try {
    const {
      id: clientId,
      date,
      name,
      brand,
      meal_type,
      scan_mode = "manual",
      confidence,
      calories = 0,
      protein = 0,
      carbs = 0,
      fat = 0,
      micronutrients = {},
      serving_size,
      servings_per_container,
      serving_quantity,
      serving_unit,
      serving_mappings = [],
      serving_type,
      serving_grams,
      serving_ml,
    } = req.body;

    if (!date || !name || !meal_type) {
      return res
        .status(400)
        .json({ error: "date, name, and meal_type are required" });
    }

    // Find or create the daily log for this date
    const logId = await findOrCreateLog(date);

    const entryId = clientId || uuid();
    const timestamp = now();

    await db.execute({
      sql: `INSERT INTO nutrition_entries 
            (id, daily_log_id, name, brand, meal_type, scan_mode, confidence,
             calories, protein, carbs, fat, micronutrients,
             serving_size, servings_per_container, serving_quantity, serving_unit,
             serving_mappings, serving_type, serving_grams, serving_ml,
             timestamp, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      args: [
        entryId,
        logId,
        name,
        brand || null,
        meal_type,
        scan_mode,
        confidence || null,
        calories,
        protein,
        carbs,
        fat,
        JSON.stringify(micronutrients),
        serving_size || null,
        servings_per_container || null,
        serving_quantity || null,
        serving_unit || null,
        JSON.stringify(serving_mappings),
        serving_type || null,
        serving_grams || null,
        serving_ml || null,
        timestamp,
        timestamp,
        timestamp,
      ],
    });

    res.status(201).json({ id: entryId, daily_log_id: logId });
  } catch (err) {
    console.error("[api] POST /entries error:", err);
    res.status(500).json({ error: err.message });
  }
});

// PUT /api/entries/:id — Update a nutrition entry
router.put("/entries/:id", async (req, res) => {
  try {
    const fields = req.body;
    const sets = [];
    const args = [];

    // Build dynamic SET clause from provided fields
    const allowedFields = [
      "name",
      "brand",
      "meal_type",
      "scan_mode",
      "confidence",
      "calories",
      "protein",
      "carbs",
      "fat",
      "serving_size",
      "servings_per_container",
      "serving_quantity",
      "serving_unit",
      "serving_type",
      "serving_grams",
      "serving_ml",
    ];

    for (const field of allowedFields) {
      if (fields[field] !== undefined) {
        sets.push(`${field} = ?`);
        args.push(fields[field]);
      }
    }

    // JSON fields need stringification
    if (fields.micronutrients !== undefined) {
      sets.push("micronutrients = ?");
      args.push(JSON.stringify(fields.micronutrients));
    }
    if (fields.serving_mappings !== undefined) {
      sets.push("serving_mappings = ?");
      args.push(JSON.stringify(fields.serving_mappings));
    }

    if (sets.length === 0) {
      return res.status(400).json({ error: "No fields to update" });
    }

    sets.push("updated_at = ?");
    args.push(now());
    args.push(req.params.id);

    await db.execute({
      sql: `UPDATE nutrition_entries SET ${sets.join(", ")} WHERE id = ?`,
      args,
    });

    res.json({ updated: true });
  } catch (err) {
    console.error("[api] PUT /entries/:id error:", err);
    res.status(500).json({ error: err.message });
  }
});

// DELETE /api/entries/:id — Delete a nutrition entry
router.delete("/entries/:id", async (req, res) => {
  try {
    await db.execute({
      sql: "DELETE FROM nutrition_entries WHERE id = ?",
      args: [req.params.id],
    });
    res.json({ deleted: true });
  } catch (err) {
    console.error("[api] DELETE /entries/:id error:", err);
    res.status(500).json({ error: err.message });
  }
});

// ═══════════════════════════════════════════════════════════════════════
// SAVED FOODS (Food Bank)
// ═══════════════════════════════════════════════════════════════════════

// GET /api/foods — List all saved foods
router.get("/foods", async (req, res) => {
  try {
    const result = await db.execute(
      "SELECT * FROM saved_foods ORDER BY created_at DESC"
    );
    res.json(result.rows.map(parseFoodRow));
  } catch (err) {
    console.error("[api] GET /foods error:", err);
    res.status(500).json({ error: err.message });
  }
});

// POST /api/foods — Create a saved food
router.post("/foods", async (req, res) => {
  try {
    const {
      id: clientId,
      name,
      brand,
      calories = 0,
      protein = 0,
      carbs = 0,
      fat = 0,
      micronutrients = {},
      serving_size,
      servings_per_container,
      serving_quantity,
      serving_unit,
      serving_mappings = [],
      serving_type,
      serving_grams,
      serving_ml,
      scan_mode = "manual",
    } = req.body;

    if (!name) {
      return res.status(400).json({ error: "name is required" });
    }

    const foodId = clientId || uuid();
    const timestamp = now();

    await db.execute({
      sql: `INSERT INTO saved_foods 
            (id, name, brand, calories, protein, carbs, fat, micronutrients,
             serving_size, servings_per_container, serving_quantity, serving_unit,
             serving_mappings, serving_type, serving_grams, serving_ml,
             scan_mode, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      args: [
        foodId,
        name,
        brand || null,
        calories,
        protein,
        carbs,
        fat,
        JSON.stringify(micronutrients),
        serving_size || null,
        servings_per_container || null,
        serving_quantity || null,
        serving_unit || null,
        JSON.stringify(serving_mappings),
        serving_type || null,
        serving_grams || null,
        serving_ml || null,
        scan_mode,
        timestamp,
        timestamp,
      ],
    });

    res.status(201).json({ id: foodId });
  } catch (err) {
    console.error("[api] POST /foods error:", err);
    res.status(500).json({ error: err.message });
  }
});

// PUT /api/foods/:id — Update a saved food
router.put("/foods/:id", async (req, res) => {
  try {
    const fields = req.body;
    const sets = [];
    const args = [];

    const allowedFields = [
      "name",
      "brand",
      "calories",
      "protein",
      "carbs",
      "fat",
      "serving_size",
      "servings_per_container",
      "serving_quantity",
      "serving_unit",
      "serving_type",
      "serving_grams",
      "serving_ml",
      "scan_mode",
    ];

    for (const field of allowedFields) {
      if (fields[field] !== undefined) {
        sets.push(`${field} = ?`);
        args.push(fields[field]);
      }
    }

    if (fields.micronutrients !== undefined) {
      sets.push("micronutrients = ?");
      args.push(JSON.stringify(fields.micronutrients));
    }
    if (fields.serving_mappings !== undefined) {
      sets.push("serving_mappings = ?");
      args.push(JSON.stringify(fields.serving_mappings));
    }

    if (sets.length === 0) {
      return res.status(400).json({ error: "No fields to update" });
    }

    sets.push("updated_at = ?");
    args.push(now());
    args.push(req.params.id);

    await db.execute({
      sql: `UPDATE saved_foods SET ${sets.join(", ")} WHERE id = ?`,
      args,
    });

    res.json({ updated: true });
  } catch (err) {
    console.error("[api] PUT /foods/:id error:", err);
    res.status(500).json({ error: err.message });
  }
});

// DELETE /api/foods/:id — Delete a saved food
router.delete("/foods/:id", async (req, res) => {
  try {
    await db.execute({
      sql: "DELETE FROM saved_foods WHERE id = ?",
      args: [req.params.id],
    });
    res.json({ deleted: true });
  } catch (err) {
    console.error("[api] DELETE /foods/:id error:", err);
    res.status(500).json({ error: err.message });
  }
});

// ═══════════════════════════════════════════════════════════════════════
// TRACKED CONTAINERS
// ═══════════════════════════════════════════════════════════════════════

// GET /api/containers — List all tracked containers
router.get("/containers", async (req, res) => {
  try {
    const result = await db.execute(
      "SELECT * FROM tracked_containers ORDER BY start_date DESC"
    );
    res.json(result.rows.map(parseContainerRow));
  } catch (err) {
    console.error("[api] GET /containers error:", err);
    res.status(500).json({ error: err.message });
  }
});

// POST /api/containers — Create a tracked container
router.post("/containers", async (req, res) => {
  try {
    const {
      id: clientId,
      food_name,
      food_brand,
      calories_per_serving,
      protein_per_serving,
      carbs_per_serving,
      fat_per_serving,
      micronutrients_per_serving = {},
      grams_per_serving,
      start_weight,
      saved_food_id,
    } = req.body;

    if (!food_name || !calories_per_serving || !grams_per_serving || !start_weight) {
      return res.status(400).json({
        error: "food_name, calories_per_serving, grams_per_serving, and start_weight are required",
      });
    }

    const containerId = clientId || uuid();
    const timestamp = now();

    await db.execute({
      sql: `INSERT INTO tracked_containers 
            (id, food_name, food_brand, calories_per_serving, protein_per_serving,
             carbs_per_serving, fat_per_serving, micronutrients_per_serving,
             grams_per_serving, start_weight, start_date, saved_food_id,
             created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      args: [
        containerId,
        food_name,
        food_brand || null,
        calories_per_serving,
        protein_per_serving || 0,
        carbs_per_serving || 0,
        fat_per_serving || 0,
        JSON.stringify(micronutrients_per_serving),
        grams_per_serving,
        start_weight,
        timestamp,
        saved_food_id || null,
        timestamp,
        timestamp,
      ],
    });

    res.status(201).json({ id: containerId });
  } catch (err) {
    console.error("[api] POST /containers error:", err);
    res.status(500).json({ error: err.message });
  }
});

// PUT /api/containers/:id — Update a tracked container (e.g. set final weight)
router.put("/containers/:id", async (req, res) => {
  try {
    const { final_weight, completed_date } = req.body;
    const sets = ["updated_at = ?"];
    const args = [now()];

    if (final_weight !== undefined) {
      sets.push("final_weight = ?");
      args.push(final_weight);
    }
    if (completed_date !== undefined) {
      sets.push("completed_date = ?");
      args.push(completed_date);
    }

    args.push(req.params.id);

    await db.execute({
      sql: `UPDATE tracked_containers SET ${sets.join(", ")} WHERE id = ?`,
      args,
    });

    res.json({ updated: true });
  } catch (err) {
    console.error("[api] PUT /containers/:id error:", err);
    res.status(500).json({ error: err.message });
  }
});

// DELETE /api/containers/:id — Delete a tracked container
router.delete("/containers/:id", async (req, res) => {
  try {
    await db.execute({
      sql: "DELETE FROM tracked_containers WHERE id = ?",
      args: [req.params.id],
    });
    res.json({ deleted: true });
  } catch (err) {
    console.error("[api] DELETE /containers/:id error:", err);
    res.status(500).json({ error: err.message });
  }
});

// ═══════════════════════════════════════════════════════════════════════
// USER GOALS
// ═══════════════════════════════════════════════════════════════════════

// GET /api/goals — Get current user goals
router.get("/goals", async (req, res) => {
  try {
    const result = await db.execute(
      "SELECT * FROM user_goals WHERE id = 'default'"
    );
    if (result.rows.length === 0) {
      return res.json({
        calorie_goal: 2000,
        protein_goal: 150,
        carbs_goal: 250,
        fat_goal: 65,
      });
    }
    res.json(result.rows[0]);
  } catch (err) {
    console.error("[api] GET /goals error:", err);
    res.status(500).json({ error: err.message });
  }
});

// PUT /api/goals — Update user goals
router.put("/goals", async (req, res) => {
  try {
    const { calorie_goal, protein_goal, carbs_goal, fat_goal } = req.body;

    await db.execute({
      sql: `UPDATE user_goals 
            SET calorie_goal = ?, protein_goal = ?, carbs_goal = ?, fat_goal = ?, updated_at = ?
            WHERE id = 'default'`,
      args: [
        calorie_goal ?? 2000,
        protein_goal ?? 150,
        carbs_goal ?? 250,
        fat_goal ?? 65,
        now(),
      ],
    });

    res.json({ updated: true });
  } catch (err) {
    console.error("[api] PUT /goals error:", err);
    res.status(500).json({ error: err.message });
  }
});

// ═══════════════════════════════════════════════════════════════════════
// SYNC — Bulk fetch for initial app load
// ═══════════════════════════════════════════════════════════════════════

// GET /api/sync — Returns all data for initial sync
// Query params: ?since=ISO_TIMESTAMP (optional, for incremental sync)
router.get("/sync", async (req, res) => {
  try {
    const { since } = req.query;

    let logsQuery, entriesQuery, foodsQuery, containersQuery;

    if (since) {
      // Incremental sync — only items changed since the given timestamp
      logsQuery = db.execute({
        sql: "SELECT * FROM daily_logs WHERE updated_at > ? ORDER BY date DESC",
        args: [since],
      });
      entriesQuery = db.execute({
        sql: "SELECT * FROM nutrition_entries WHERE updated_at > ? ORDER BY timestamp ASC",
        args: [since],
      });
      foodsQuery = db.execute({
        sql: "SELECT * FROM saved_foods WHERE updated_at > ? ORDER BY created_at DESC",
        args: [since],
      });
      containersQuery = db.execute({
        sql: "SELECT * FROM tracked_containers WHERE updated_at > ? ORDER BY start_date DESC",
        args: [since],
      });
    } else {
      // Full sync — everything
      logsQuery = db.execute(
        "SELECT * FROM daily_logs ORDER BY date DESC"
      );
      entriesQuery = db.execute(
        "SELECT * FROM nutrition_entries ORDER BY timestamp ASC"
      );
      foodsQuery = db.execute(
        "SELECT * FROM saved_foods ORDER BY created_at DESC"
      );
      containersQuery = db.execute(
        "SELECT * FROM tracked_containers ORDER BY start_date DESC"
      );
    }

    const goalsQuery = db.execute(
      "SELECT * FROM user_goals WHERE id = 'default'"
    );

    // Run all queries in parallel
    const [logs, entries, foods, containers, goals] = await Promise.all([
      logsQuery,
      entriesQuery,
      foodsQuery,
      containersQuery,
      goalsQuery,
    ]);

    res.json({
      daily_logs: logs.rows,
      nutrition_entries: entries.rows.map(parseEntryRow),
      saved_foods: foods.rows.map(parseFoodRow),
      tracked_containers: containers.rows.map(parseContainerRow),
      user_goals: goals.rows[0] || null,
      synced_at: now(),
    });
  } catch (err) {
    console.error("[api] GET /sync error:", err);
    res.status(500).json({ error: err.message });
  }
});

// ═══════════════════════════════════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════════════════════════════════

// Find or create a daily log for a given date
async function findOrCreateLog(date) {
  // Normalize to just the date portion (YYYY-MM-DD)
  const normalizedDate = date.substring(0, 10);

  const existing = await db.execute({
    sql: "SELECT id FROM daily_logs WHERE date = ?",
    args: [normalizedDate],
  });

  if (existing.rows.length > 0) {
    return existing.rows[0].id;
  }

  const logId = uuid();
  const timestamp = now();

  await db.execute({
    sql: "INSERT INTO daily_logs (id, date, created_at, updated_at) VALUES (?, ?, ?, ?)",
    args: [logId, normalizedDate, timestamp, timestamp],
  });

  return logId;
}

// Parse JSON fields in a nutrition entry row
function parseEntryRow(row) {
  return {
    ...row,
    micronutrients: safeJsonParse(row.micronutrients, {}),
    serving_mappings: safeJsonParse(row.serving_mappings, []),
  };
}

// Parse JSON fields in a saved food row
function parseFoodRow(row) {
  return {
    ...row,
    micronutrients: safeJsonParse(row.micronutrients, {}),
    serving_mappings: safeJsonParse(row.serving_mappings, []),
  };
}

// Parse JSON fields in a tracked container row
function parseContainerRow(row) {
  return {
    ...row,
    micronutrients_per_serving: safeJsonParse(
      row.micronutrients_per_serving,
      {}
    ),
  };
}

// Safely parse JSON, returning fallback on error
function safeJsonParse(str, fallback) {
  if (!str) return fallback;
  try {
    return JSON.parse(str);
  } catch {
    return fallback;
  }
}

module.exports = router;
