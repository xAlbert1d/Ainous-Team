---
name: tone-enforce
description: Ensures consistent voice and style across outputs — code comments, docs, commit messages, error messages. Use when reviewing multi-author docs or maintaining project voice.
---

# Tone & Style Enforcement

## Core Principle

Consistency builds trust. Inconsistent tone makes a project feel disorganized even when the code is solid.

## Technique

### Step 1: Define Voice Rules
Before enforcing, establish what the voice IS:
- **Formality level**: casual / professional / academic
- **Perspective**: first person plural ("we") / second person ("you") / impersonal
- **Vocabulary**: technical jargon allowed? Abbreviations? Colloquialisms?
- **Sentence structure**: short and direct? Or detailed and thorough?

### Step 2: Apply to Output
- Read through the entire piece first
- Mark inconsistencies: tone shifts, vocabulary changes, perspective switches
- Fix each inconsistency to match the defined voice rules
- Pay special attention to transitions between sections (common drift points)

### Step 3: Check for Drift
- Compare first paragraph to last — same voice?
- Check error messages match the tone of success messages
- Verify code comments match doc comments
- Ensure CLI output matches README examples

## Common Voice Profiles

| Profile | Tone | Example |
|---------|------|---------|
| **Technical docs** | Precise, impersonal, present tense | "The function returns null when..." |
| **README** | Friendly, second person, imperative | "Run `npm install` to get started" |
| **Error messages** | Direct, actionable, no blame | "File not found. Check the path and try again." |
| **Commit messages** | Concise, imperative mood, no period | "Fix race condition in auth middleware" |
| **Code comments** | Brief, explain WHY not WHAT | "// Retry because the API returns stale data on first call" |

## Anti-Patterns

- **Corporate-speak in code comments**: "Leveraging synergies to optimize throughput" — just say what the code does
- **Casual tone in security advisories**: "Oops, there's a little auth bug" — security needs gravity
- **Inconsistent terminology**: using "user", "client", "customer", and "account holder" for the same entity
- **Tone whiplash**: cheerful README followed by hostile error messages
