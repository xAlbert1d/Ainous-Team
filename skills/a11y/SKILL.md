---
name: a11y
description: Accessibility compliance — WCAG, screen readers, keyboard navigation, color contrast, semantic HTML, ARIA. Use when building or reviewing UI, ensuring legal compliance, or improving usability for all users.
---

# Accessibility (a11y)

## Core Principle

Accessibility is not a feature — it's a quality attribute. If 15% of your users can't use your product, you have a bug, not a missing feature.

## WCAG Quick Reference

Four principles (POUR):

| Principle | Meaning | Key Tests |
|-----------|---------|-----------|
| **Perceivable** | Users can perceive the content | Color contrast, alt text, captions |
| **Operable** | Users can operate the interface | Keyboard nav, no time limits, no seizure triggers |
| **Understandable** | Users can understand the content | Clear language, consistent navigation, error prevention |
| **Robust** | Content works with assistive tech | Valid HTML, ARIA roles, screen reader testing |

## Concrete Checks

### Visual
- **Color contrast**: text ≥ 4.5:1 ratio (AA), large text ≥ 3:1
- **Color not sole indicator**: don't use red/green alone for error/success — add icons or text
- **Text resizable**: content readable at 200% zoom without horizontal scroll
- **Focus visible**: interactive elements have a visible focus ring (never `outline: none` without replacement)

### Keyboard
- **Tab order**: logical flow through interactive elements (matches visual order)
- **All actions reachable**: every click target must be reachable via keyboard
- **No keyboard traps**: user can always Tab out of any component
- **Skip links**: "Skip to main content" link for screen reader users
- **Escape closes**: modals, dropdowns, popups close on Escape key

### Semantic HTML
- Use `<button>` for actions, `<a>` for navigation — not `<div onclick>`
- Use heading hierarchy: `h1 → h2 → h3` (never skip levels)
- Use `<nav>`, `<main>`, `<aside>`, `<footer>` landmarks
- Use `<label>` for form inputs (connected via `for`/`id`)
- Tables need `<th>` headers and `scope` attributes

### ARIA (when semantic HTML isn't enough)
- **Rule 1**: don't use ARIA if native HTML does the job. `<button>` > `<div role="button">`
- **Roles**: `role="dialog"`, `role="alert"`, `role="tablist"` — only for custom widgets
- **States**: `aria-expanded`, `aria-selected`, `aria-disabled` — keep in sync with visual state
- **Labels**: `aria-label` for icons without text, `aria-describedby` for supplementary descriptions

### Screen Reader
- **Alt text**: every `<img>` has meaningful alt text (or `alt=""` for decorative images)
- **Live regions**: `aria-live="polite"` for dynamic content updates (notifications, loading states)
- **Hidden content**: `aria-hidden="true"` for decorative elements screen readers should skip

## Testing Approach

1. **Automated**: axe-core, Lighthouse accessibility audit — catches ~30% of issues
2. **Keyboard**: Tab through the entire page. Can you do everything without a mouse?
3. **Screen reader**: test with VoiceOver (Mac) or NVDA (Windows). Does the content make sense read aloud?
4. **Zoom**: 200% browser zoom. Does the layout break?
5. **Color**: simulate colorblindness (DevTools → Rendering → Emulate vision deficiencies)

## When to Use

- Building any user-facing interface
- Before releasing UI changes
- During design reviews (catch issues before implementation)
- When receiving accessibility bug reports
- Legal compliance reviews (ADA, Section 508, EAA)

## Anti-Patterns

- **Accessibility last**: retrofitting a11y after launch is 10x more expensive than building it in
- **ARIA overuse**: adding `role`, `aria-label` to everything. Most of the time, semantic HTML is sufficient.
- **Testing only with automated tools**: automated tools catch 30%. Keyboard and screen reader testing catches the rest.
- **"Screen reader users don't use our product"**: you don't know that. They might try and leave because it's unusable.
- **Hiding skip links permanently**: skip links should be visible on focus, not hidden with `display: none`
