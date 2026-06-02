# Getting the most out of newer models

Everything described here is optional. The plugin ships with no dependency on any particular model
generation or Claude Code version. If you never read this page, the plugin works exactly as
documented in the README.

If you are on a Claude Code version that supports the features below, each one is a targeted
opt-in you apply by editing a single file. An older Claude Code that does not recognise a
frontmatter key silently ignores it — nothing breaks.

Test one change at a time. If a role starts behaving unexpectedly after you add a frontmatter
field, remove it and the role returns to its previous behavior.

---

## 1. Model tiers — nothing to configure

The plugin uses family aliases (`opus`, `sonnet`, `haiku`) in every agent definition, never dated
model identifiers such as `claude-opus-4-8-20261001`. Claude Code resolves each alias to the
latest available model in that family at spawn time.

That means newer models (4.8 and beyond) make the team work better automatically, without any
action on your part. The coordinator, architect, and security roles gain deeper reasoning; the
retriever stays cheap. You do not need to update the plugin or any configuration file when a new
model generation ships.

---

## 2. `effort:` frontmatter — deeper reasoning on demand

If your Claude Code version supports the `effort` frontmatter field, you can raise or lower the
reasoning budget per role.

**Roles that benefit from higher effort:**

Add `effort: xhigh` to `agents/architect.md` and `agents/security.md`:

```yaml
---
name: architect
model: opus
effort: xhigh          # add this line
tools: [Read, Write, Edit, Grep, Glob, Bash]
---
```

```yaml
---
name: security
model: opus
effort: xhigh          # add this line
tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
---
```

When to use it: complex greenfield design tasks (architect) or deep threat-model passes (security).
Not every task warrants extended reasoning — the default effort level is appropriate for most work.

**Roles where lower effort saves cost:**

Add `effort: low` to `agents/retriever.md`:

```yaml
---
name: retriever
model: haiku
effort: low            # add this line
tools: [Read, Grep, Glob, Agent]
---
```

The retriever's job is pattern-matching and filtering, not reasoning. Lower effort keeps retrieval
calls cheap without affecting output quality.

**Compatibility note:** if your Claude Code version does not support `effort`, the field is treated
as an unknown frontmatter key and ignored. The role runs at its default effort level. If you are
unsure whether your version supports it, add `effort: xhigh` to one role, run a task that spawns
it, and check whether the behavior changes as expected before editing additional files.

---

## 3. `opusplan` — plan on Opus, execute on Sonnet

If your Claude Code version supports the `opusplan` model specifier, you can switch the coordinator
from `opus` to `opusplan` in `agents/coordinator.md`:

```yaml
---
name: coordinator
model: opusplan        # was: opus
tools: [Read, Write, Grep, Glob, Bash, Agent]
---
```

`opusplan` runs the planning phase on Opus and the execution phase on Sonnet. For the coordinator
this is usually a good trade: planning is where Opus earns its cost; synthesis and delegation are
lighter work.

**Caveat — 200K context window during the plan phase.** Opus operates with a 200K context window
during planning. On long multi-phase sessions where the coordinator has accumulated significant
conversation history, the plan phase may hit that limit before execution begins. If you see
context-truncation warnings or incomplete plans, switch back to `opus` (full window) for that
session.

---

## 4. `opus[1m]` — 1M context for long sessions

If your Claude Code version supports extended-context specifiers, you can give the coordinator a
1M token window:

```yaml
---
name: coordinator
model: opus[1m]        # was: opus
tools: [Read, Write, Grep, Glob, Bash, Agent]
---
```

When to use it: long multi-phase sessions where the coordinator must hold the full history of
spawned roles, phase outputs, and verification gates in context simultaneously.

**Plan availability:** `opus[1m]` is available on Max, Team, and Enterprise plans. It is not
available on standard Pro plans. Attempting to use it on an unsupported plan will fall back to the
standard Opus window or produce an error, depending on your Claude Code version — check your plan
details before enabling.

---

## 5. Bedrock, Vertex, and Azure Foundry — resolving the `opus` alias

On Bedrock, Vertex, and Azure Foundry deployments, the `opus` alias may resolve to an earlier
Opus generation rather than the latest. If you want a specific model version on these platforms,
set the environment variable before starting Claude Code:

```bash
export ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-8-20261001
```

Replace the model ID with whichever version is available and approved in your deployment. The
`sonnet` and `haiku` aliases follow the same resolution logic — set
`ANTHROPIC_DEFAULT_SONNET_MODEL` and `ANTHROPIC_DEFAULT_HAIKU_MODEL` if you need pinned versions
for those families as well.

This only matters if you are on a managed cloud deployment where the alias does not resolve to the
model generation you expect. Standard Anthropic API users can ignore this section.

---

## Summary

| Opt-in | File to edit | When it helps |
|--------|-------------|---------------|
| `effort: xhigh` | `agents/architect.md`, `agents/security.md` | Deep design or threat-model tasks |
| `effort: low` | `agents/retriever.md` | Reducing cost on lookup-only calls |
| `model: opusplan` | `agents/coordinator.md` | Saving cost on planning-heavy sessions |
| `model: opus[1m]` | `agents/coordinator.md` | Very long multi-phase sessions (Max/Team/Enterprise) |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | Shell environment | Pinning a specific version on Bedrock/Vertex/Foundry |

All of these are reversible. Revert any file to its shipped state and the plugin behaves exactly as
it did before.
