# From White-Pixel Flood Fill to Semantic Food Icons

OpenFoodJournal originally generated every Food Bank image on white and offered a manual “Pixel Pass” that removed border-connected near-white pixels. That worked for dark foods, but it could not distinguish white rice from a white background. This change replaces color guessing with contrast-aware generation and Apple Vision subject lifting.

## The Starting Point

Nano Banana 2 Lite returned a 1024 px JPEG, which the app resized to a 160 px opaque thumbnail. Pixel Pass then walked inward from the thumbnail’s border and changed sufficiently white pixels into alpha.

That design had two structural problems:

- The algorithm understood RGB values, not food. Rice, cauliflower, frosting, reflections, and pale shadows could resemble the background.
- Every generated food used white, so light foods began with weak boundaries before masking even started.

The context-menu action also made cleanup a manual repair instead of part of image generation.

## Step 1: Test the Provider Before Designing the Fix

I generated brownie, rice, blackberry, and cauliflower icons with three prompt styles: the current white baseline, an adaptive opposite-luminance rule, and an explicitly chosen background. Adaptive prompting correctly chose warm off-white for all dark foods and charcoal for all light foods in the sample.

I also tried requesting transparent PNG output. The concrete Lite endpoint returned HTTP 400 and stated that only `image/jpeg` was supported. That ruled out the simplest architecture: the provider cannot currently be the source of alpha for this model contract.

The generated “exact” background colors were close but not byte-identical to the requested hex values. That matters because a better color threshold would still be a threshold—JPEG compression and generated lighting would keep making it brittle.

## Step 2: Make Contrast Part of Generation

The production instruction now asks the model to classify the food’s dominant brightness before rendering:

```text
For a dark food, use a uniform warm off-white background.
For a light food, use a uniform charcoal background.
No gradient, texture, floor, glow, or cast shadow.
```

The input JSON also carries `background_policy: automatic opposite luminance`. Keeping the rule in both the system instruction and request-specific input makes the contract explicit and gives tests something stable to assert.

## Step 3: Replace Pixel Pass with Meaning

`VNGenerateForegroundInstanceMaskRequest` is Apple Vision’s subject-lifting request. Instead of asking whether a pixel is “white enough,” it identifies noticeable foreground objects and produces a full-resolution mask.

`VisionFoodIconForegroundMasker` runs in its own actor so synchronous Vision and Core Image work does not block the main UI actor. It combines every detected foreground instance, applies the mask as alpha, resizes after masking, and stores a compact PNG.

The pipeline deliberately fails soft:

```swift
semantic PNG
    ?? compact opposite-contrast JPEG
    ?? original generated JPEG
```

A failed mask never discards a successful generation and never triggers another billable provider call. Coverage outside 2–85% is treated as implausible and uses the opaque fallback.

## The Gotcha: Vision Failed on the Development Mac

The experiment’s macOS Vision request failed while loading Apple’s subject-lifting Neural Engine plan, even when CPU-only execution was requested. That was a host runtime limitation, not a reason to return to pixel thresholds. The iOS code still receives an SDK typecheck, while the production fallback keeps icons usable if the same condition occurs on a device.

The remaining manual smoke test is therefore important: generate dark and light foods on the TestFlight build, confirm PNG alpha on-device, and confirm that an unavailable Vision mask leaves a clean contrast JPEG.

## Step 4: Remove the Retired Search Surface

The same release removes Food Bank AI Search from the `+` menu and deletes its sheet. Open Food Facts remains the structured Food Bank search path, while the Assistant retains provider-neutral web research. Legacy `.aiSearch` diagnostic and usage decoding remains so older persisted records do not break.

## What’s Next

- Exercise semantic masking on physical devices with rice, cauliflower, blackberries, reflective packaging, and multi-piece foods.
- Record only redacted mask method/success metadata, never image content.
- Consider an explicit-background retry only if adaptive classification proves unreliable across a larger sample.
- Keep the opaque contrast image as the permanent no-surprises fallback.

---

A mask should understand the subject, not merely memorize the color behind it.
