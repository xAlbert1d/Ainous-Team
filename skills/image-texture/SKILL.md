---
name: image-texture
description: "Author a gpt-image-2 SEAMLESS tileable texture prompt and hand off to codex-image-gen. Triggers: tileable texture, seamless pattern, repeating background pattern."
---

# Image Texture

Follow the conventions in image-craft-base; this skill specializes them for seamless tileable textures.

## Key Move

Include this phrase verbatim in the CONSTRAINTS section:

> "Seamless tileable, edges wrap continuously, flat even lighting, no center focal point, no edge gradient."

Run the generation as a **session-isolated single run** — do not batch this prompt with other image prompts in the same `codex exec` call. Cross-prompt context can bleed into the tiling behavior.

## Failure Modes to Prevent

- **Visible seams** — caused by missing wrap constraint or directional lighting that doesn't match at edges.
- **Baked vignette** — gpt-image-2 darkens edges by default. This breaks tiling visually. Always de-vignette in post: `magick -level 10%,90% tile.png tile-flat.png` (ImageMagick 7; use `convert` on ImageMagick 6) or equivalent. Tell the user this post step is required.

## Default Size / Quality

1024×1024 / medium (or 2048×2048 for high-res surfaces)

## Sample Cue

> "Seamless tileable subtle linen weave, top-down view, uniform field, flat even lighting, no shadows, no center focal point, no edge gradient, pale #F5F0E8 base."

## Handoff

Build the 5-section prompt per image-craft-base. In your response to the user, include the de-vignette post-processing step — it is not optional.

See codex-image-gen for auth check, cost go-ahead, the `codex exec -s workspace-write` run, and the look-at-the-output verification step.
