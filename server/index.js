// OpenFoodJournal — Server
// 1. Gemini proxy: accepts food images → Gemini → structured nutrition JSON
// 2. REST API: CRUD operations for all entities backed by Turso (libSQL)
// AGPL-3.0 License

// ── Dependencies ──────────────────────────────────────────────────────
const express = require("express");
const multer = require("multer"); // Parses multipart/form-data (image uploads)
const cors = require("cors"); // Allows cross-origin requests from any client
const { GoogleGenerativeAI } = require("@google/generative-ai");
require("dotenv").config(); // Loads .env file for local development

const { runMigrations } = require("./db");
const apiRoutes = require("./routes");

// ── Configuration ─────────────────────────────────────────────────────
const PORT = process.env.PORT || 3000;
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;

// Validate that the API key is present — server can't function without it
if (!GEMINI_API_KEY) {
  console.error("FATAL: GEMINI_API_KEY environment variable is required");
  process.exit(1);
}

// ── Initialize Express & Middleware ───────────────────────────────────
const app = express();

// Allow requests from any origin (the iOS app and any future web clients)
app.use(cors());

// Parse JSON bodies for any non-file endpoints
app.use(express.json());

// Configure multer to hold uploaded images in memory (no disk writes)
// Limit to 10MB to prevent abuse
const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 10 * 1024 * 1024 }, // 10 MB max
});

// ── Initialize Gemini Client ──────────────────────────────────────────
const genAI = new GoogleGenerativeAI(GEMINI_API_KEY);

// Gemini 3.1 Flash Lite — fast, lightweight model optimized for OCR/extraction tasks
// Significantly lower latency than full Flash for structured data extraction from labels.
// MINIMAL thinking reduces reasoning overhead — labels are straightforward extraction,
// not complex analysis. This should cut Gemini processing time.
const flashModel = genAI.getGenerativeModel({
  model: "gemini-3.1-flash-lite-preview",
  generationConfig: {
    responseMimeType: "application/json",
    thinkingConfig: {
      thinkingLevel: "MINIMAL",
    },
  },
});

// Fallback model for label scans when Flash Lite is overloaded (500/503)
const flashFallback = genAI.getGenerativeModel({
  model: "gemini-2.5-flash",
  generationConfig: {
    responseMimeType: "application/json",
  },
});

// Gemini 3.1 Pro — high-reasoning model for food photo estimation
// Uses thinking/reasoning for more accurate portion size and nutrient estimates
// thinkingLevel replaces thinkingBudget for Gemini 3+ models (Google recommendation)
// Values: "low" | "medium" | "high" — "high" is default for 3.1 Pro anyway,
// but explicit config documents intent and survives model name changes.
const proModel = genAI.getGenerativeModel({
  model: "gemini-3.1-pro-preview",
  generationConfig: {
    responseMimeType: "application/json",
    thinkingConfig: {
      thinkingLevel: "HIGH",
    },
  },
});

// Fallback for food photo scans when Pro is overloaded
const proFallback = genAI.getGenerativeModel({
  model: "gemini-2.5-pro",
  generationConfig: {
    responseMimeType: "application/json",
    thinkingConfig: {
      thinkingLevel: "HIGH",
    },
  },
});

// ── Prompt Templates ──────────────────────────────────────────────────
// Two modes: "label" (nutrition label photo) and "food_photo" (photo of food)
// Both return the same JSON structure, but the prompts differ in what they ask.

const LABEL_PROMPT = `You are a nutrition label reader. Analyze this nutrition label image and extract ALL nutritional information.

Return a JSON object with this EXACT structure:
{
  "name": "<product name if visible, otherwise 'Unknown Product'>",
  "brand": "<brand name if visible, otherwise null>",
  "confidence": <0.0-1.0 how confident you are in the reading>,
  "serving_size": "<serving size text, e.g. '1 cup (228g)'>",
  "serving_quantity": <numeric serving amount, e.g. 1.0>,
  "serving_unit": "<unit string, e.g. 'cup', 'g', 'piece', 'tbsp'>",
  "serving_weight_grams": <weight of one serving in grams if shown, otherwise null>,
  "servings_per_container": <number or null>,
  "serving_type": "<'mass' if only grams known, 'volume' if only volume known, 'both' if both grams and volume are shown, otherwise null>",
  "serving_grams": <gram weight of ONE serving as a number, or null if unknown>,
  "serving_ml": <volume of ONE serving in mL as a number, or null if not a liquid/volume serving>,
  "calories": <number>,
  "protein": <grams as number>,
  "carbs": <grams as number>,
  "fat": <grams as number>,
  "micronutrients": {
    "<nutrient_id>": {"value": <number>, "unit": "<g|mg|mcg|IU|%>"},
    ...include ALL nutrients visible on the label
  }
}

IMPORTANT — Use these canonical nutrient IDs as JSON keys:
Vitamins: vitamin_a, vitamin_c, vitamin_d, vitamin_e, vitamin_k, thiamin, riboflavin, niacin, pantothenic_acid, vitamin_b6, biotin, folate, vitamin_b12
Minerals: calcium, iron, magnesium, phosphorus, potassium, sodium, zinc, copper, manganese, selenium, chromium, molybdenum, iodine, chloride
Other: fiber, added_sugars, cholesterol, saturated_fat, trans_fat

If a nutrient not in this list appears on the label, use a lowercase_snake_case ID for it.

Rules:
- Extract EVERY nutrient shown on the label, not just the common ones
- Use the exact values shown on the label
- For brand: look for the brand/manufacturer name on the packaging
- For serving_quantity and serving_unit: parse the serving size into number + unit (e.g. "2 cookies" → quantity: 2, unit: "cookies")
- For serving_weight_grams: if the label shows weight in grams (e.g. "1 cup (228g)"), extract the gram value as a number
- For serving_type: use "mass" if only grams are given, "volume" if only a volume unit is given (mL, cup, tbsp, etc.), "both" if the label shows both a weight and a volume for the same serving
- For serving_grams: the gram weight of exactly ONE serving (NOT per container). Use serving_weight_grams if available.
- For serving_ml: the mL volume of ONE serving. Convert if label shows other volume units (1 cup = 240 mL, 1 tbsp = 15 mL, 1 fl oz = 30 mL). Omit (null) for solid foods.
- For "% Daily Value" only nutrients, convert to actual amounts if possible, otherwise use "%" as unit
- Use the canonical nutrient IDs listed above as micronutrient keys
- If a value is 0, still include it
- confidence should reflect image clarity and how readable the label is`;

const FOOD_PHOTO_PROMPT = `You are a nutrition estimation expert. Look at this photo of food and estimate its nutritional content.

Return a JSON object with this EXACT structure:
{
  "name": "<descriptive name of the food/meal>",
  "brand": "<brand name if recognizable, otherwise null>",
  "confidence": <0.0-1.0 how confident you are in the estimation>,
  "serving_size": "<estimated portion description>",
  "serving_quantity": <estimated numeric serving amount>,
  "serving_unit": "<unit string, e.g. 'piece', 'cup', 'bowl', 'plate'>",
  "serving_weight_grams": <estimated weight in grams>,
  "servings_per_container": 1,
  "serving_type": "<'mass' if weight is the primary measure, 'volume' if volume is the primary measure, 'both' if both apply>",
  "serving_grams": <estimated gram weight of the shown portion>,
  "serving_ml": <estimated volume in mL if relevant, e.g. for drinks, otherwise null>,
  "calories": <estimated number>,
  "protein": <estimated grams>,
  "carbs": <estimated grams>,
  "fat": <estimated grams>,
  "micronutrients": {
    "<nutrient_id>": {"value": <number>, "unit": "<g|mg|mcg|IU>"},
    ...include common nutrients you can reasonably estimate
  }
}

IMPORTANT — Use these canonical nutrient IDs as JSON keys:
Vitamins: vitamin_a, vitamin_c, vitamin_d, vitamin_e, vitamin_k, thiamin, riboflavin, niacin, pantothenic_acid, vitamin_b6, biotin, folate, vitamin_b12
Minerals: calcium, iron, magnesium, phosphorus, potassium, sodium, zinc, copper, manganese, selenium, chromium, molybdenum, iodine, chloride
Other: fiber, added_sugars, cholesterol, saturated_fat, trans_fat

If a nutrient not in this list is relevant, use a lowercase_snake_case ID for it.

Rules:
- Be realistic about portion sizes shown in the image
- Estimate based on typical nutritional values for the identified food
- For serving_weight_grams: estimate the total weight of the food portion in grams
- For serving_type: use "mass" for solid foods, "volume" for drinks/liquids, "both" if both weight and volume are naturally described
- For serving_grams: estimated gram weight of the single portion shown
- For serving_ml: estimated mL for beverages/liquids (null for solid foods)
- confidence should be lower than label scans since these are estimates
- Include at least fiber, sodium, cholesterol, saturated_fat in micronutrients if estimable
- Use the canonical nutrient IDs listed above as micronutrient keys`;

// ── Routes ────────────────────────────────────────────────────────────

// Health check — Render pings this to know the service is alive
app.get("/health", (_req, res) => {
  res.json({ status: "ok", timestamp: new Date().toISOString() });
});

// POST /scan — Main endpoint. Accepts multipart form with "image" and "mode"
// "mode" is either "label" (nutrition label) or "food_photo" (photo of food)
app.post("/scan", upload.single("image"), async (req, res) => {
  try {
    const serverStart = Date.now();

    // ── Validate request ──────────────────────────────────────────
    if (!req.file) {
      return res.status(400).json({ error: "No image file provided. Send as 'image' field." });
    }

    // Default to "label" mode if not specified
    const mode = req.body.mode || "label";
    if (!["label", "food_photo"].includes(mode)) {
      return res.status(400).json({ error: "Invalid mode. Use 'label' or 'food_photo'." });
    }

    console.log(`[scan] mode=${mode}, size=${req.file.size} bytes, mime=${req.file.mimetype}`);

    // ── Pick the right prompt based on scan mode ──────────────────
    const prompt = mode === "label" ? LABEL_PROMPT : FOOD_PHOTO_PROMPT;

    console.log(`[scan] Using model: ${mode === "label" ? "gemini-flash-lite" : "gemini-pro (thinking)"}`);

    // ── Convert uploaded image to the format Gemini expects ───────
    // Gemini needs base64-encoded image data with a MIME type
    const imagePart = {
      inlineData: {
        mimeType: req.file.mimetype || "image/jpeg",
        data: req.file.buffer.toString("base64"),
      },
    };

    const prepMs = Date.now() - serverStart;

    // ── Call Gemini API with automatic fallback on 500/503 ────────
    const primaryModel = mode === "label" ? flashModel : proModel;
    const fallbackModel = mode === "label" ? flashFallback : proFallback;
    let usedFallback = false;

    const geminiStart = Date.now();
    let result;
    try {
      result = await primaryModel.generateContent([prompt, imagePart]);
    } catch (primaryErr) {
      const msg = primaryErr.message || "";
      if (msg.includes("500") || msg.includes("503") || msg.includes("overloaded") || msg.includes("high demand")) {
        console.log(`[scan] Primary model failed (${msg.substring(0, 80)}), falling back...`);
        usedFallback = true;
        result = await fallbackModel.generateContent([prompt, imagePart]);
      } else {
        throw primaryErr;
      }
    }
    const geminiMs = Date.now() - geminiStart;
    const responseText = result.response.text();

    if (usedFallback) {
      console.log(`[scan] Fallback model succeeded (${mode === "label" ? "gemini-2.5-flash" : "gemini-2.5-pro"})`);
    }

    console.log(`[scan] Gemini responded with ${responseText.length} chars`);

    // ── Parse and validate the response ───────────────────────────
    // Gemini returns JSON (we set responseMimeType), but parse to validate
    let nutritionData;
    try {
      nutritionData = JSON.parse(responseText);
    } catch (parseErr) {
      console.error("[scan] Failed to parse Gemini JSON:", responseText);
      return res.status(502).json({ error: "Gemini returned invalid JSON" });
    }

    // ── Ensure required fields exist ──────────────────────────────
    // The iOS app requires these four macros at minimum
    const required = ["calories", "protein", "carbs", "fat"];
    const missing = required.filter((f) => nutritionData[f] === undefined);
    if (missing.length > 0) {
      console.error("[scan] Missing fields:", missing);
      return res.status(502).json({
        error: `Gemini response missing required fields: ${missing.join(", ")}`,
      });
    }

    // ── Set defaults for optional fields ──────────────────────────
    nutritionData.name = nutritionData.name || "Unknown Food";
    nutritionData.confidence = nutritionData.confidence ?? 0.5;
    nutritionData.micronutrients = nutritionData.micronutrients || {};

    const totalMs = Date.now() - serverStart;
    console.log(`[scan] ⏱️ Server timing: total=${totalMs}ms (prep=${prepMs}ms, gemini=${geminiMs}ms, post=${totalMs - prepMs - geminiMs}ms)`);

    // Include server timing in the response for client-side breakdown
    nutritionData.server_timing = {
      total_ms: totalMs,
      gemini_ms: geminiMs,
      prep_ms: prepMs,
    };

    // ── Return the structured nutrition data ──────────────────────
    res.json(nutritionData);
  } catch (err) {
    console.error("[scan] Error:", err.message || err);

    // Differentiate between Gemini API errors and server errors
    if (err.message?.includes("API key")) {
      return res.status(500).json({ error: "Invalid Gemini API key configuration" });
    }
    if (err.message?.includes("SAFETY")) {
      return res.status(422).json({ error: "Image was blocked by safety filters" });
    }

    res.status(500).json({ error: "Internal server error processing scan" });
  }
});

// ── Mount REST API routes ─────────────────────────────────────────────
app.use("/api", apiRoutes);

// ── Start Server ──────────────────────────────────────────────────────
// Run database migrations before accepting requests
runMigrations()
  .then(() => {
    app.listen(PORT, () => {
      console.log(`OpenFoodJournal server listening on port ${PORT}`);
      console.log(`Gemini models: 3.1 Flash Lite (labels), 3.1 Pro w/ thinking (food photos)`);
      console.log(`API routes mounted at /api/*`);
    });
  })
  .catch((err) => {
    console.error("Failed to run migrations:", err);
    process.exit(1);
  });
