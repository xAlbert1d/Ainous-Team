---
name: diagram
description: Converts concepts, architectures, and workflows into renderable diagrams using Mermaid syntax. Use when creating architecture docs, design handoffs, README visuals, or system overviews.
---

# Diagram Generator

## Core Principle

A diagram should answer ONE question at a glance. If the viewer needs to study it for 30 seconds, it's too complex — split it.

## Technique

### Step 1: Identify Diagram Type
| Data Shape | Diagram Type | Mermaid Syntax |
|-----------|-------------|----------------|
| Process flow | Flowchart | `graph TD` or `graph LR` |
| Time sequence | Sequence diagram | `sequenceDiagram` |
| Object relationships | Class diagram | `classDiagram` |
| State transitions | State diagram | `stateDiagram-v2` |
| Data model | ER diagram | `erDiagram` |
| Timeline | Gantt | `gantt` |
| Hierarchy | Mindmap | `mindmap` |

### Step 2: Extract Entities
- List all nodes (actors, components, services, states)
- List all edges (calls, depends on, transitions to, contains)
- Label every edge — unlabeled edges are ambiguous

### Step 3: Generate Mermaid
- Use Mermaid syntax (renders in GitHub, VS Code, docs tools)
- Keep to ≤15 nodes per diagram. More → split into sub-diagrams.
- Use subgraphs to group related nodes
- Direction: TD (top-down) for hierarchies, LR (left-right) for flows

### Step 4: Validate
- Does every node connect to at least one other node? (no orphans)
- Does the diagram answer the original question without reading surrounding text?
- Would a new team member understand it without additional explanation?

## Anti-Patterns

- **Spaghetti diagram**: every node connects to every other node. Simplify — show the primary flow, not every possible connection.
- **Missing edge labels**: an arrow without a label could mean anything
- **Wrong type**: using a flowchart for time-ordered interactions (use sequence diagram)
- **Too detailed**: including implementation details in an architecture overview
- **No legend**: using colors or shapes without explaining what they mean
