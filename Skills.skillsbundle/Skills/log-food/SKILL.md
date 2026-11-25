---
name: log-food
description: Log what someone ate or drank in OpenFoodJournal, including saved Food Bank foods, brand clarification, serving amounts, known label nutrition, unfamiliar foods, multiple foods, or logging followed by checking the journal.
---

This is for recording food the person actually ate, not just looking up nutrition. Keep their stated date, meal, amount, and unit throughout the interaction.

- For a food identified in the active Food Bank with an unambiguous name, brand, and portion, prefer the **Log a Food Bank Item** tool. It uses the saved portion conversions. If needed, use **Find Saved Foods** to narrow the identity and resolve the matching Food Bank Item for logging by its exact name and brand; the search result is the separate Saved Food entity. If the food or brand is ambiguous, ask which of the returned candidates they mean. Never pick the most recent or first brand just because it appears first.
- If the person speaks a freeform food description, is uncertain which saved food matches, or has no saved food, prefer **Log Food**. It searches the active Food Bank itself and handles brand clarification and estimate review. Keep the original food, portion, meal, and date when answering a clarification; a brand-only reply is not a new food to log.
- If the person supplies actual nutrition for a specific portion and wants to log those values directly, use **Log Food With Known Nutrition** instead. Nutrition must describe the entire specified portion. Ask about missing calories or macros rather than inventing values or treating unknown values as zero.
- Ask for the missing quantity or unit when the meaning is unclear. For an explicit serving, use the saved serving; don't assume that a serving is a cup or 100 grams. If a conversion fails, clarify the unit or use the stored units from **Read Food Bank Details**. Do not silently substitute a different portion. If a nutrition calculator requires ingredient selection, ask the person to finish choosing ingredients in the app.
- If the lookup needs extended research or hands off to **Ask Assistant to Log Food**, explain that the food is not yet logged. Let the existing Assistant flow continue rather than calling another logging tool on the same request.

For several explicitly requested foods, keep the portions distinct and confirm each through the applicable logging tool. Wait for the tool's result before doing any further action. If the request also asks to see the updated journal or daily totals, use **Read Journal Entries** or **Read Journal Nutrition Summary** after a successful save, using that same local date. Do not claim a save succeeded on a preview, a handoff, an error, or a cancelled confirmation. Do not retry a write automatically or log the same meal again when the result is uncertain; first check the journal and ask if needed.

Only log on an explicit request. Never change a Food Bank template, prior journal entry, or nutrition goal as part of logging unless the person separately asks for that change.
