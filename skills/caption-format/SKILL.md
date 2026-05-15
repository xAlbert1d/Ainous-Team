---
name: caption-format
description: Formats captions and subtitles for readability, timing, and accessibility. Produces SRT/VTT format output. Use when publishing videos, ensuring accessibility compliance, or adding multilingual subtitles.
---

# Caption & Subtitle Formatter

## Core Principle

Captions are read under time pressure. Every formatting choice should reduce cognitive load.

## Rules

### Line Length
- Maximum 42 characters per line
- Maximum 2 lines per caption block
- Break at natural phrase boundaries, not mid-word or mid-clause

### Timing
- Display for 1-6 seconds (never less than 1, never more than 6)
- Reading speed: 150-200 words per minute
- Minimum gap between captions: 0.2 seconds (prevents visual merging)
- Sync to speech: caption appears when the word is spoken, not before

### Positioning
- Default: bottom center
- Move to top when bottom is obstructed (lower thirds, graphics, text on screen)
- Speaker identification when multiple speakers: `[Speaker Name]: text`

### Accessibility
- Describe relevant non-speech audio: `[music playing]`, `[door slams]`, `[laughter]`
- Indicate emphasis: ALL CAPS for shouting (sparingly), *italics* for emphasis
- Include sound effects that carry meaning: `[alarm beeping]`, `[notification sound]`

## SRT Format

```
1
00:00:01,000 --> 00:00:04,500
This is the first caption
with a second line.

2
00:00:05,000 --> 00:00:08,200
And this is the second caption.
```

## VTT Format

```
WEBVTT

00:00:01.000 --> 00:00:04.500
This is the first caption
with a second line.

00:00:05.000 --> 00:00:08.200
And this is the second caption.
```

## Line Break Rules

- GOOD: `The server processes\nthe request in 45ms` (break at phrase boundary)
- BAD: `The server processes the\nrequest in 45ms` (breaks mid-phrase)
- GOOD: `When the build completes,\ncheck the output directory` (break at comma)
- BAD: `When the build\ncompletes, check the output directory` (breaks clause)

## Anti-Patterns

- **Lines too long**: wrapping captions are unreadable — enforce 42-char limit
- **Too many lines**: 3+ lines on screen overwhelms the viewer
- **Desync**: captions that appear 1-2 seconds after speech — frustrating
- **Missing speaker identification**: two people talking, no labels — who said what?
- **No non-speech audio**: deaf viewers miss context — describe meaningful sounds
