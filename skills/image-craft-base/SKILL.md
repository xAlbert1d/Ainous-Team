---
name: image-craft-base
description: "Shared craft conventions for the image-* gpt-image-2 skills — 5-section prompt template, style-anchor format, size/aspect table, and the transparency/text/tiling/safe-zone rules. Reference note for the image-* skills; not invoked directly."
invocable: false
---

# Image Craft Base

## Role of This File

This is the single source of truth for conventions shared across every `image-*` skill. Each artifact skill opens by referencing it. Do not invoke this file directly — use the appropriate artifact skill instead.

## 1 — The 5-Section Prompt Template

Order is load-bearing. Write sections in this sequence; the USE CASE slot sets the model's generation mode:

```
SCENE       — environment, setting, camera angle, lighting
SUBJECT     — the main visual element(s)
IMPORTANT DETAILS — palette (hex codes), texture, mood, secondary elements
USE CASE    — intended artifact type (hero banner / icon / texture / OG card / etc.)
CONSTRAINTS — technical exclusions and must-haves
```

**SCENE** anchors spatial context first. **CONSTRAINTS** always comes last and appends to the universal constraints line below — artifact skills add their own exclusions on top.

## 2 — Universal Constraints Line

Append this verbatim to every CONSTRAINTS section (artifact skills then append their own exclusions after it):

> "High resolution, sharp focus, no watermark, no signature, no stock-photo borders. No extra, duplicate, or garbled text."

## 3 — STYLE-ANCHOR Block

The STYLE-ANCHOR is the only consistency mechanism on gpt-image-2 — there is no seed parameter and no `--sref` flag. When generating a set, paste the STYLE-ANCHOR paragraph **identically** into every prompt in the set.

**Format:**

```
STYLE-ANCHOR: <visual style name> — palette <HEX1>/<HEX2>/<HEX3>, <rendering technique>,
<lighting descriptor>, <texture descriptor>. Paste this block identically for every image in this set.
```

**Strongest consistency path:** generate all N images in ONE run as a CONSISTENT SERIES (single `codex exec` invocation asking for all N). gpt-image-2 also accepts a reference image via `-i` (vision input — the model sees the image as context). Attaching a prior set member via `-i` can help orient the model toward your established style, but it is NOT a style-lock: there is no seed parameter and no `--sref` equivalent, so results can still vary. The verbatim STYLE-ANCHOR paragraph in every prompt, combined with the one-run series, is the primary and most reliable consistency mechanism.

## 4 — Size / Aspect / Quality Table

| Artifact | Generate size (×16-valid) | Deliver / crop to | Aspect | Quality tier |
|---|---|---|---|---|
| Hero / banner | 2880×1616 | crop to taste (e.g. 2880×1620 is fine after crop) | 16:9 | high |
| Icon / favicon / logo | 1024×1024 | 1024×1024 | 1:1 | high |
| Seamless texture | 1024×1024 (or 2048×2048) | same | 1:1 | medium |
| Background (full-bleed) | 2560×1440 | 2560×1440 | 16:9 | medium |
| OG / social card | 1216×640 | crop/resize to 1200×630 | ~1.91:1 | high |
| Story (9:16) | 1088×1920 | crop to 1080×1920 | 9:16 | high |
| Thumbnail | 1280×720 | 1280×720 | 16:9 | medium |
| Spot illustration | 1024×1024 | 1024×1024 | 1:1 | high |

**Hard rails (model limits):** max edge 3840 px; both edges must be multiples of 16 (generation size — final delivery size can differ after crop/resize); max aspect ratio 3:1; quality tiers are `low`, `medium`, `high` — no others.

## 5 — Cross-Cutting Rules

**(a) No transparent background.** gpt-image-2 cannot output a transparent PNG — it always composites onto a background. To get a transparent asset: generate on a named solid flat color (e.g., `flat #FFFFFF background`) then remove the background in post (e.g., `rembg`, Figma, or Photoshop). Alternatively route to gpt-image-1.5 which supports transparency natively. Never silently ship a baked white background as if it were transparent.

**(b) Verbatim text.** Quote the exact string in the prompt (e.g., `headline reads exactly "Ship faster"`). Append `"no extra, duplicate, or garbled text"` to CONSTRAINTS. Use `quality=high` — text accuracy degrades at lower quality tiers. Verify spelling visually after generation.

**(c) Seamless tiling.** gpt-image-2 bakes vignetting (darker edges) into images by default — this breaks tiling. To get a seamless tile: include `"seamless tileable, edges wrap continuously, flat even lighting, no center focal point, no edge gradient"` in the prompt, then **de-vignette in post** (e.g., `magick -level 10%,90% tile.png tile-flat.png` for ImageMagick 7; use `convert` on ImageMagick 6). Run the generation as a session-isolated single run to prevent cross-contamination from other prompts.

**(d) Meta 9:16 safe zone (March 2026).** For stories and 9:16 content, keep all key content and text out of: top 14%, bottom 20–35%, sides 6%. Safe zone = center band roughly 80% wide × 51–66% tall.

## 6 — Delegation Rule

Auth check, cost go-ahead, the `codex exec -s workspace-write` invocation, and the look-at-the-output verification are **codex-image-gen's job**. This layer only authors the prompt string. That string is the gpt-image-2 prompt passed as codex-image-gen's description argument.
