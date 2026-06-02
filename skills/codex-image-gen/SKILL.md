---
name: codex-image-gen
description: Generate production raster images by driving the OpenAI Codex CLI (gpt-image-2). Use when you need real image assets — hero art, textures, icons, thumbnails, OG/social cards — created and saved into a project without your own image-API key. Triggers: "generate an image", "make a hero/background/icon", "I have Codex, use it for images".
---

# Codex Image Generation

## Core Principle

Codex is a *coding agent*, not an image button — you generate images by giving `codex exec` a prompt that says **"generate ONE image of X and save it to this exact path,"** then you **open the result and look at it** before trusting it. Never ship an image you have not visually verified.

## Background (why this works)

OpenAI Codex (`com.openai.codex`, the desktop app bundles a `codex` CLI) gained native image generation (gpt-image-2) in April 2026. If the user is logged in (`codex login status` → "Logged in using ChatGPT"), image generation runs under their plan with **no separate API key**. You invoke it by running the agent non-interactively (`codex exec`) and asking it, in plain language, to generate and save image files. The agent uses its built-in image tool, writes candidates to `~/.codex/generated_images/…`, then copies/resizes the chosen one to the path you specified.

## Phase 1 — Pre-flight

Locate the CLI and confirm auth before generating:

```bash
BIN="/Applications/Codex.app/Contents/Resources/codex"   # or: which codex
"$BIN" login status        # must say: Logged in using ChatGPT (or via API key)
```

- Each run spends the user's account quota (~35k–90k tokens per image/run). **Before a batch, state the plan + rough cost and get a go-ahead** — you are spawning an autonomous agent on their account.
- Decide the **exact filename, path, pixel size, and aspect ratio up front** (see Phase 2). Getting the aspect ratio right the first time avoids a regenerate.

## Phase 2 — Generate

Run from (or pass `-C`) the project dir, with the **workspace-write** sandbox (writes confined to the project — never `--dangerously-bypass-approvals-and-sandbox`):

```bash
"$BIN" exec -C /abs/project/dir -s workspace-write \
  "Generate ONE <aspect> image and save it as public/hero.png (generate at 2880x1616; resize/crop with sips if the native size differs).
   STYLE: <concrete style — palette HEXES, mood, texture; e.g. glowing blue #5C8DFF + lime #B5D44A circuit-nebula on obsidian #0A0B0F>.
   COMPOSITION: <constraints — e.g. keep the LEFT 38% dark and quiet for headline text; bloom centered-right; vertically centered so a cover-crop never cuts the focal point>.
   NO text, NO logos, NO literal objects unless asked.
   Produce exactly that one file." \
  --output-last-message /tmp/codex_msg.txt 2>&1 | tail -8
```

Prompt recipe that reliably lands:
- **"Generate ONE image … save it as `<exact/path.ext>` … produce exactly that one file."** Pin the count and the path or the file won't be where you need it.
- **Size + "resize/crop with sips if needed."** Match the aspect ratio to the use (16:9 hero, 1:1 icon/thumbnail, 1200x630 OG). Ask for high resolution; don't let it hand back a small upscaled image.
- **Composition constraints** for images that sit under text: name the region to keep dark/empty ("left 40% dark for the headline"), and "vertically centered so a cover-crop is safe."
- **Palette as hex codes** and an explicit style; say what to exclude (no text/letters/objects).
- **Consistent set?** Ask for all N in ONE run as "a CONSISTENT SERIES, same visual language, differing only by <color/concept>, save each to public/kind-<x>.png" — gpt-image-2 keeps a series coherent better than N separate runs.

## Phase 3 — Verify and iterate (mandatory)

```bash
ls -la public/hero.png && file public/hero.png   # exists? right dimensions?
```

Then **Read the image file** (it renders visually) and judge it against the brief. If it's off — wrong crop, soft/upscaled, bright where text goes, wrong concept — **regenerate with a tuned prompt** (sharper size/aspect, stronger composition constraint). Do not wire an unseen image into a UI.

If it's a background under live text, also screenshot the page with it in place (e.g. headless Chrome) — an image that looks fine alone can destroy legibility behind a headline.

## Phase 4 — Optimize for the web

gpt-image-2 PNGs are large (a hero can be ~5 MB). Convert decorative images to WebP before shipping (typically 90–97% smaller):

```bash
cwebp -q 85 public/hero.png -o public/hero.webp        # brew install webp
# macOS `sips -s format webp` is unreliable on some versions — prefer cwebp
```
Keep PNG for favicons and OG/social cards (broad scraper/OS compatibility); convert hero/textures/thumbnails to WebP and update references.

## Anti-Patterns

- **Shipping unseen images.** Building "blind" and wiring an image you never opened — it will be wrong. Always `Read` the file (and screenshot if it's behind text).
- **Wrong aspect/size up front.** Generating a 2.4:1 image for a near-square hero area → ugly upscaled crop. Match aspect to the use and request real resolution; one regenerate is cheaper than a soft hero.
- **Not pinning the output path.** Without "save as `<exact path>`, produce exactly that one file," Codex leaves images in `~/.codex/generated_images/` and you scramble to find/copy them.
- **Batch-spending silently.** Firing off many runs without flagging cost — it's the user's account quota. Confirm scope first.
- **Using the dangerous bypass.** `--dangerously-bypass-approvals-and-sandbox` is never needed here; `-s workspace-write` lets it save into the project safely.
- **Assuming `-i/--image` generates.** That flag *attaches* an input image (vision), it does not generate one. Generation is driven by the prompt text.
- **Forgetting WebP.** A 5 MB hero PNG tanks load time; convert decorative assets before deploy.

## When to Use

- You need real raster assets in a project (hero/background art, ambient textures, per-item thumbnails, app icon/favicon, OG/social card) and the user has Codex logged in.
- You do NOT have (or don't want to wire) a direct image-generation API key.

**When NOT to use:** vector/UI that should be CSS/SVG (don't generate a PNG for a divider line or a gradient); precise text-in-image beyond a short wordmark (verify spelling if you do); or anything where the user hasn't authorized spending their Codex/account quota.
