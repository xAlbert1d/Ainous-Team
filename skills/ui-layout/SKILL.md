---
name: ui-layout
description: Advises on interface layouts for clarity, spacing, hierarchy, and usability. Provides concrete CSS/HTML suggestions. Use for frontend development, design reviews, and component layouts.
---

# UI/UX Layout Advisor

## Core Principle

Visual hierarchy tells users what to do without reading. If they have to search for the primary action, the layout has failed.

## Audit Process

### Step 1: Check Hierarchy
- What's the most important element? Is it visually dominant (largest, boldest, highest contrast)?
- Is there a clear reading flow? (F-pattern for text-heavy, Z-pattern for landing pages)
- Are there competing focal points? (If yes, pick one winner)

### Step 2: Check Spacing
- Consistent spacing scale: 4 / 8 / 16 / 24 / 32 / 48 / 64px
- Related elements closer together, unrelated elements farther apart (Gestalt proximity)
- Padding inside containers ≥ gap between them
- Touch targets ≥ 44×44px on mobile

### Step 3: Check Accessibility
- Color contrast ratio ≥ 4.5:1 for text (WCAG AA)
- Don't use color as the ONLY indicator (add icons, text, or patterns)
- Interactive elements have visible focus states
- Text is readable at 16px minimum body size

### Step 4: Suggest Improvements
- Provide concrete CSS or Tailwind classes, not abstract advice
- BAD: "make the button more prominent"
- GOOD: "increase button padding to `px-6 py-3`, use `bg-blue-600 text-white font-semibold`"

## Layout Patterns

| Pattern | Use When | Key Rule |
|---------|----------|----------|
| **Stack** | Forms, settings, lists | Consistent gap between items |
| **Grid** | Cards, galleries, dashboards | Equal columns, consistent gutters |
| **Split** | Hero sections, comparison | Clear visual weight balance |
| **Sidebar** | Navigation + content | Sidebar narrower than content (1:3 ratio) |
| **Centered** | Login, landing, error pages | Max-width constraint (640-768px) |

## Anti-Patterns

- **Competing CTAs**: two equally prominent buttons — "Save" and "Cancel" should have visual weight difference
- **Inconsistent padding**: 12px here, 15px there, 20px elsewhere. Pick a scale and stick to it.
- **Wall of text**: no visual breaks in long content. Add headings, whitespace, or dividers.
- **Tiny tap targets**: interactive elements smaller than 44px — frustrating on mobile
- **Color-only meaning**: red for error, green for success, with no icon or text — fails for colorblind users
