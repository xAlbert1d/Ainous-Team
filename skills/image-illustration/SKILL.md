---
name: image-illustration
description: "Author a gpt-image-2 spot-illustration or CONSISTENT-series prompt and hand off to codex-image-gen. Triggers: spot illustration, illustration set, matching series, consistent illustrations."
---

# Image Illustration

Follow the conventions in image-craft-base; this skill specializes them for spot illustrations and consistent illustration sets.

## Key Move

Paste the **STYLE-ANCHOR block** (see image-craft-base §3) **identically** into every prompt in the set. For a multi-image set, use codex-image-gen's one-run CONSISTENT SERIES path: ask for all N in a single `codex exec` call with "save each to `public/illus-<n>.png`". This is more coherent than N separate runs — gpt-image-2 has no seed to lock across runs.

## Failure Mode to Prevent

**Set drifts in style or palette** — gpt-image-2 has no seed parameter. Without the STYLE-ANCHOR pasted identically and the one-run series approach, illustrations 2–N will drift from illustration 1 in rendering style, weight, and palette. Do not assume visual consistency across separate runs. Note: even within a single run, visual drift is still possible; re-roll or tighten the style anchor if it drifts.

## Default Size / Quality

1024×1024 / high

## Sample Cue

**Single spot illustration:**
> "Spot illustration of a person reading at a desk, STYLE-ANCHOR: flat vector + soft grain — palette #2E3A59/#F4A261/#FAF9F6, rounded shapes, 2px stroke, warm soft ambient light. Paste this block identically for every image in this set."

**Consistent set of 4:**
> "A CONSISTENT SERIES of 4 spot illustrations, same visual language, differing only by subject (reading / writing / presenting / collaborating). STYLE-ANCHOR: flat vector + soft grain — palette #2E3A59/#F4A261/#FAF9F6, rounded shapes, 2px stroke, warm soft ambient light. Paste this block identically for every image in this set. Save as public/illus-1.png through public/illus-4.png. Produce exactly those 4 files."

## Handoff

Build the 5-section prompt per image-craft-base with the STYLE-ANCHOR embedded, then pass it to codex-image-gen. For sets, confirm the one-run CONSISTENT SERIES approach and verify all N files exist and are visually consistent before handing off.

See codex-image-gen for auth check, cost go-ahead, the `codex exec -s workspace-write` run, and the look-at-the-output verification step.
