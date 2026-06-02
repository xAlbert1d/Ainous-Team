---
name: image-thumbnail
description: "Author a gpt-image-2 thumbnail prompt and hand off to codex-image-gen. Triggers: make a thumbnail, video thumbnail, card image, list thumbnail."
---

# Image Thumbnail

Follow the conventions in image-craft-base; this skill specializes them for thumbnails.

## Key Move

One bold, high-contrast focal element that reads clearly when the image is shrunk to ~320px. The focal subject should fill roughly 60% of the frame. For face thumbnails, specify a clear, expressive emotion — ambiguous expressions read as flat at small size.

## Failure Modes to Prevent

- **Too many focal elements** — multiple competing subjects turn to mush at thumbnail size. One subject, one read.
- **Low-contrast text** — if the brief includes a headline overlay, specify black outline or a dark semi-opaque band behind it. Verify legibility at 320px width.

## Default Size / Quality

1280×720 / medium

## Sample Cue

> "Bold single-subject thumbnail, high contrast, simple clean background, focal object fills 60% of frame, palette #FFFFFF bg / #1A1A1A subject, 2–4 word headline reads exactly 'The big reveal', bold sans with black outline, no other text."

## Handoff

Build the 5-section prompt per image-craft-base, then pass it to codex-image-gen. After generation, verify the image at reduced size (~320px wide) — details that look fine at full resolution can merge into noise at thumbnail dimensions.

See codex-image-gen for auth check, cost go-ahead, the `codex exec -s workspace-write` run, and the look-at-the-output verification step.
