---
name: docs
description: Technical documentation principles. Use when writing READMEs, guides, API docs, inline comments, or any prose that another human must act on. Invoke before drafting any documentation artifact.
---

# Technical Documentation

## Core Principle

Documentation exists for the READER, not the writer. If the reader cannot act on what you wrote, it failed — regardless of how thorough or accurate it is.

## Three-Stage Process

### 1. Context Gathering
Before writing a single line, answer: Who reads this? What do they need to DO after reading? What do they already know? A guide for a new developer joining the project differs fundamentally from an ops runbook for a production incident.

### 2. Structure and Draft
Lead with what the reader needs most. If they need to install something, the install command goes in the first screen — not after three paragraphs of history. Use progressive disclosure: essential information first, details and edge cases later.

### 3. Verification
Hand your draft to someone with no prior context. Can they follow it and succeed? If they get stuck, the doc failed at that point. Fix the doc, not the reader.

## Audience-First Writing

Every doc has exactly one primary audience. Trying to serve everyone serves no one. Name your audience in the first line of your outline. Write for their vocabulary, their context, their goals.

## Anti-Slop Rules

Never use "simply", "just", or "easily" — these dismiss complexity and make the reader feel stupid when they struggle. Never use "robust", "scalable", "comprehensive" — these are filler that conveys nothing. Show, do not tell. A concrete example beats a paragraph of abstract description every time.

Bad: "Simply run the migration script to easily update your database."
Good: "Run `./migrate.sh` — this takes 2-5 minutes and requires write access to the database."

## Structure Principles

- **Lead with the answer.** Inverted pyramid: conclusion first, supporting details after.
- **Headings are scannable questions.** "How do I deploy?" beats "Deployment Procedures".
- **Code examples are worth 1000 words.** A working snippet communicates faster than prose.
- **Paragraphs under 4 sentences.** Long paragraphs signal that you are covering multiple ideas — split them.

## What NOT to Document

Do not document what the code already says. `// increment counter` above `counter++` is noise. Document WHY, not WHAT. Document gotchas: "This function silently returns null on network failure" saves someone hours of debugging. Document non-obvious behavior and surprising constraints.

## README Checklist

Every project README answers four questions, in order:
1. **What is this?** One sentence. What problem does it solve?
2. **How do I install/run it?** Copy-pasteable commands.
3. **How do I use it?** The most common use case, with a working example.
4. **How do I contribute?** Where to file bugs, how to run tests, any conventions.

## The Freshness Problem

Outdated documentation is worse than no documentation — it actively misleads. If you cannot commit to maintaining a doc, keep it minimal. Prefer docs that live close to the code they describe (inline comments, co-located READMEs) over centralized wikis that rot. Automate what you can: generated API docs from types, CLI help from source.
