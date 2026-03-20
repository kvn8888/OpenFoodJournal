// OpenFoodJournal — Gemini Proxy Server
// Accepts food images, sends to Google Gemini for nutrition analysis,
// and returns structured JSON matching the iOS app's expected format.
// AGPL-3.0 License

// ── Dependencies ──────────────────────────────────────────────────────
const express = require("express");
const multer = require("multer"); // Parses multipart/form-data (image uploads)
const cors = require("cors"); // Allows cross-origin requests from any client
const { GoogleGenerativeAI } = require("@google/generative-ai");
require("dotenv").config(); // Loads .env file for local development

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

// Use Gemini Pro — fast, multimodal, good at structured extraction
const model = genAI.getGenerativeModel({
  model: "gemini-3.1-pro-preview",
  generationConfig: {
    // Tell Gemini to return valid JSON matching our schema
    responseMimeType: "application/json",
  },
});

// ── Prompt Templates ──────────────────────────────────────────────────
// Two modes: "label" (nutrition label photo) and "food_photo" (photo of food)
// Both return the same JSON structure, but the prompts differ in what they ask.

const LABEL_PROMPT = `You are a nutrition label reader. Analyze this nutrition label image and extract ALL nutritional information.

Return a JSON object with this EXACT structure:
{
  "name": "<product name if visible, otherwise 'Unknown Product'>",
  "confidence": <0.0-1.0 how confident you are in the reading>,
  "serving_size": "<serving size text, e.g. '1 cup (228g)'>",
  "servings_per_container": <number or null>,
  "calories": <number>,
  "protein": <grams as number>,
  "carbs": <grams as number>,
  "fat": <grams as number>,
  "micronutrients": {
    "<Nutrient Name>": {"value": <number>, "unit": "<g|mg|mcg|IU|%>"},
    ...include ALL nutrients visible on the label (fiber, sugar, sodium, cholesterol, saturated fat, trans fat, vitamins, minerals, etc.)
  }
}

Rules:
- Extract EVERY nutrient shown on the label, not just the common ones
- Use the exact values shown on the label
- For "% Daily Value" only nutrients, convert to actual amounts if possible, otherwise use "%" as unit
- Nutrient names should be Title Case (e.g. "Saturated Fat", "Vitamin D", "Added Sugars")
- If a value is 0, still include it
- confidence should reflect image clarity and how readable the label is`;

const FOOD_PHOTO_PROMPT = `You are a nutrition estimation expert. Look at this photo of food and estimate its nutritional content.

Return a JSON object with this EXACT structure:
{
  "name": "<descriptive name of the food/meal>",
  "confidence": <0.0-1.0 how confident you are in the estimation>,
  "serving_size": "<estimated portion description>",
  "servings_per_container": 1,
  "calories": <estimated number>,
  "protein": <estimated grams>,
  "carbs": <estimated grams>,
  "fat": <estimated grams>,
  "micronutrients": {
    "<Nutrient Name>": {"value": <number>, "unit": "<g|mg|mcg|IU>"},
    ...include common nutrients you can reasonably estimate (fiber, sugar, sodium, etc.)
  }
}

Rules:
- Be realistic about portion sizes shown in the image
- Estimate based on typical nutritional values for the identified food
- confidence should be lower than label scans since these are estimates
- Include at least fiber, sugar, and sodium in micronutrients if you can estimate them
- Nutrient names should be Title Case`;

// ── Routes ────────────────────────────────────────────────────────────

// Health check — Render pings this to know the service is alive
app.get("/health", (_req, res) => {
  res.json({ status: "ok", timestamp: new Date().toISOString() });
});

// POST /scan — Main endpoint. Accepts multipart form with "image" and "mode"
// "mode" is either "label" (nutrition label) or "food_photo" (photo of food)
app.post("/scan", upload.single("image"), async (req, res) => {
  try {
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

    // ── Convert uploaded image to the format Gemini expects ───────
    // Gemini needs base64-encoded image data with a MIME type
    const imagePart = {
      inlineData: {
        mimeType: req.file.mimetype || "image/jpeg",
        data: req.file.buffer.toString("base64"),
      },
    };

    // ── Call Gemini API ───────────────────────────────────────────
    const result = await model.generateContent([prompt, imagePart]);
    const responseText = result.response.text();

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

// ── Start Server ──────────────────────────────────────────────────────
app.listen(PORT, () => {
  console.log(`OpenFoodJournal proxy listening on port ${PORT}`);
  console.log(`Gemini model: gemini-3.1-pro-preview`);
});
