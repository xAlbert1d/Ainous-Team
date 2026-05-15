#!/usr/bin/env bats
# promotion-review.bats — Tests for the consolidator promotion diff-review feature
#
# Coverage:
#   - PR-1: Consolidator emit — synthetic emit produces file with expected fields
#   - PR-2: Coordinator session-start surface — reads file and produces expected one-line output
#   - PR-3: Veto path — source entry deleted → consolidator skips promotion on next cycle
#
# Run: bats tests/bats/promotion-review.bats
# Exit 0 = all tests pass.
#
# Design constraint: no test writes to ~/.claude/ or .claude/ in the real project.
# Every test uses an isolated BATS_TEST_TMPDIR subtree.

# ---------------------------------------------------------------------------
# Shared constants
# ---------------------------------------------------------------------------
PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

# ---------------------------------------------------------------------------
# setup() — called before each @test
# ---------------------------------------------------------------------------
setup() {
    FAKE_PROJECT="$BATS_TEST_TMPDIR/project"
    mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/consolidator"
    mkdir -p "$FAKE_PROJECT/.claude/ainous-roles/developer"

    REVIEW_FILE="$FAKE_PROJECT/.claude/ainous-roles/consolidator/promotion-review.jsonl"
    TEAM_KNOWLEDGE="$FAKE_PROJECT/.claude/ainous-roles/team-knowledge.md"
    PLAYBOOK="$FAKE_PROJECT/.claude/ainous-roles/developer/playbook.md"

    # Sample source entry for team-knowledge
    SOURCE_ENTRY="- **Tests use bats framework** (discovered by: researcher, as of 2026-04-17) [consolidated]"

    # Sample new playbook strategy being promoted
    TARGET_ENTRY="## run-bats-before-commit\nmaturity: shu\nWhen modifying test infrastructure, run bats tests first."
}

# teardown() — bats-core removes BATS_TEST_TMPDIR automatically
teardown() {
    : # nothing to do
}

# ===========================================================================
# PR-1 — Consolidator emit
# Simulate the consolidator writing a promotion-review entry and verify the
# file exists with the correct structure and all required fields.
# ===========================================================================

@test "PR-1a: Emit creates promotion-review.jsonl with all required fields" {
    # Simulate consolidator emit via Python (matches the procedure in consolidator-instructions.md)
    python3 - "$REVIEW_FILE" <<'PYEOF'
import json, pathlib, datetime, sys

review_file = pathlib.Path(sys.argv[1])
review_file.parent.mkdir(parents=True, exist_ok=True)

entry = {
    "timestamp": "2026-04-17T10:00:00Z",
    "consolidator_session": "2026-04-17",
    "target_file": ".claude/ainous-roles/developer/playbook.md",
    "target_entry_excerpt": "## run-bats-before-commit\nmaturity: shu\nWhen modifying test infrastructure",
    "source_carrier": "team-knowledge",
    "source_entries": [
        {
            "file": ".claude/ainous-roles/team-knowledge.md",
            "excerpt": "- **Tests use bats framework** (discovered by: researcher, as of 2026-04-17) [consolidated]",
            "provenance": {}
        }
    ],
    "upstream_chain": ["observed"],
    "reasoning": "team-knowledge fact promoted to developer playbook strategy",
    "reviewed": None,
    "rejected": None,
}

with review_file.open("a") as f:
    f.write(json.dumps(entry) + "\n")
PYEOF

    # File must exist
    [ -f "$REVIEW_FILE" ]

    # Must be valid JSONL (parse the first line)
    python3 - "$REVIEW_FILE" <<'PYEOF'
import json, sys
lines = [l.strip() for l in open(sys.argv[1]) if l.strip()]
assert len(lines) == 1, f"Expected 1 line, got {len(lines)}"
entry = json.loads(lines[0])

required_fields = [
    "timestamp", "consolidator_session", "target_file", "target_entry_excerpt",
    "source_carrier", "source_entries", "upstream_chain", "reasoning",
    "reviewed", "rejected"
]
for field in required_fields:
    assert field in entry, f"Missing required field: {field}"

# Verify key field values
assert entry["source_carrier"] == "team-knowledge"
assert entry["reviewed"] is None
assert entry["rejected"] is None
assert isinstance(entry["upstream_chain"], list)
assert isinstance(entry["source_entries"], list)
assert len(entry["source_entries"]) == 1
assert "file" in entry["source_entries"][0]
assert "excerpt" in entry["source_entries"][0]
PYEOF

    [ "$?" -eq 0 ]
}

@test "PR-1b: Multiple emits append to the file (append-only semantics)" {
    # Write two entries sequentially
    python3 - "$REVIEW_FILE" <<'PYEOF'
import json, pathlib, sys

review_file = pathlib.Path(sys.argv[1])
review_file.parent.mkdir(parents=True, exist_ok=True)

base = {
    "consolidator_session": "2026-04-17",
    "target_file": ".claude/ainous-roles/developer/playbook.md",
    "target_entry_excerpt": "strategy content",
    "source_carrier": "user-corrections",
    "source_entries": [{"file": "user-corrections.md", "excerpt": "user fixed import style", "provenance": {}}],
    "upstream_chain": ["observed"],
    "reasoning": "user correction promoted to user-learned strategy",
    "reviewed": None,
    "rejected": None,
}

with review_file.open("a") as f:
    for ts in ["2026-04-17T10:00:00Z", "2026-04-17T11:00:00Z"]:
        entry = {**base, "timestamp": ts}
        f.write(json.dumps(entry) + "\n")
PYEOF

    # Must have exactly 2 lines
    line_count=$(wc -l < "$REVIEW_FILE" | tr -d ' ')
    [ "$line_count" -eq 2 ]

    # Both must be valid JSON
    python3 - "$REVIEW_FILE" <<'PYEOF'
import json, sys
lines = [l.strip() for l in open(sys.argv[1]) if l.strip()]
assert len(lines) == 2
for line in lines:
    json.loads(line)  # raises if invalid
PYEOF
    [ "$?" -eq 0 ]
}

@test "PR-1c: External-unsanitized chain is captured in upstream_chain field" {
    python3 - "$REVIEW_FILE" <<'PYEOF'
import json, pathlib, sys

review_file = pathlib.Path(sys.argv[1])
review_file.parent.mkdir(parents=True, exist_ok=True)

entry = {
    "timestamp": "2026-04-17T12:00:00Z",
    "consolidator_session": "2026-04-17",
    "target_file": ".claude/ainous-roles/coordinator/playbook.md",
    "target_entry_excerpt": "When signal reports trending tool, evaluate for adoption",
    "source_carrier": "signal-hit",
    "source_entries": [
        {
            "file": ".claude/ainous-roles/signal/findings.md",
            "excerpt": "HackerNews: tool X trending",
            "provenance": {"source": "external-unsanitized"}
        }
    ],
    "upstream_chain": ["external-unsanitized", "observed"],
    "reasoning": "signal-hit from external source promoted to coordinator strategy",
    "reviewed": None,
    "rejected": None,
}

with review_file.open("a") as f:
    f.write(json.dumps(entry) + "\n")
PYEOF

    # Verify external-unsanitized is in the upstream_chain
    python3 - "$REVIEW_FILE" <<'PYEOF'
import json, sys
lines = [l.strip() for l in open(sys.argv[1]) if l.strip()]
entry = json.loads(lines[0])
assert "external-unsanitized" in entry["upstream_chain"], \
    f"upstream_chain missing external-unsanitized: {entry['upstream_chain']}"
PYEOF
    [ "$?" -eq 0 ]
}

# ===========================================================================
# PR-2 — Coordinator session-start surface
# Simulate the coordinator reading the review file and producing the expected
# one-line summary.
# ===========================================================================

@test "PR-2a: Coordinator surface emits one line with correct counts when pending entries exist" {
    # Write 3 entries: 2 unreviewed (1 flagged external-unsanitized), 1 reviewed
    python3 - "$REVIEW_FILE" <<'PYEOF'
import json, pathlib, sys

review_file = pathlib.Path(sys.argv[1])
review_file.parent.mkdir(parents=True, exist_ok=True)

entries = [
    # Pending, not flagged
    {
        "timestamp": "2026-04-17T10:00:00Z",
        "consolidator_session": "2026-04-17",
        "target_file": "playbook.md",
        "target_entry_excerpt": "strategy A",
        "source_carrier": "team-knowledge",
        "source_entries": [],
        "upstream_chain": ["observed"],
        "reasoning": "reason A",
        "reviewed": None,
        "rejected": None,
    },
    # Pending, flagged external-unsanitized
    {
        "timestamp": "2026-04-17T11:00:00Z",
        "consolidator_session": "2026-04-17",
        "target_file": "playbook.md",
        "target_entry_excerpt": "strategy B from signal",
        "source_carrier": "signal-hit",
        "source_entries": [],
        "upstream_chain": ["external-unsanitized"],
        "reasoning": "reason B",
        "reviewed": None,
        "rejected": None,
    },
    # Already reviewed — should NOT be counted
    {
        "timestamp": "2026-04-17T09:00:00Z",
        "consolidator_session": "2026-04-17",
        "target_file": "playbook.md",
        "target_entry_excerpt": "strategy C",
        "source_carrier": "user-corrections",
        "source_entries": [],
        "upstream_chain": ["observed"],
        "reasoning": "reason C",
        "reviewed": "2026-04-17T08:00:00Z",
        "rejected": None,
    },
]

with review_file.open("w") as f:
    for e in entries:
        f.write(json.dumps(e) + "\n")
PYEOF

    # Simulate the coordinator session-start check (bash logic from coordinator-instructions.md)
    result=$(bash <<SHELL
REVIEW_FILE="$REVIEW_FILE"
if [ -f "\$REVIEW_FILE" ]; then
    PENDING=\$(grep -c '"reviewed": null' "\$REVIEW_FILE" 2>/dev/null || echo 0)
    FLAGGED=\$(grep '"reviewed": null' "\$REVIEW_FILE" 2>/dev/null | grep -c '"external-unsanitized"' || echo 0)
    if [ "\$PENDING" -gt 0 ]; then
        echo "\${PENDING} pending promotions (\${FLAGGED} flagged external-unsanitized) — see .claude/ainous-roles/consolidator/promotion-review.jsonl"
    fi
fi
SHELL
    )

    # Must produce exactly one output line
    line_count=$(echo "$result" | grep -c .)
    [ "$line_count" -eq 1 ]

    # Must contain "2 pending promotions"
    [[ "$result" == *"2 pending promotions"* ]]

    # Must contain "(1 flagged external-unsanitized)"
    [[ "$result" == *"1 flagged external-unsanitized"* ]]

    # Must reference the file path
    [[ "$result" == *"promotion-review.jsonl"* ]]
}

@test "PR-2b: Coordinator surface emits nothing when no pending entries" {
    # Write only already-reviewed entries
    python3 - "$REVIEW_FILE" <<'PYEOF'
import json, pathlib, sys

review_file = pathlib.Path(sys.argv[1])
review_file.parent.mkdir(parents=True, exist_ok=True)

entry = {
    "timestamp": "2026-04-17T10:00:00Z",
    "consolidator_session": "2026-04-17",
    "target_file": "playbook.md",
    "target_entry_excerpt": "strategy",
    "source_carrier": "team-knowledge",
    "source_entries": [],
    "upstream_chain": ["observed"],
    "reasoning": "reason",
    "reviewed": "2026-04-17T12:00:00Z",
    "rejected": None,
}

with review_file.open("w") as f:
    f.write(json.dumps(entry) + "\n")
PYEOF

    result=$(bash <<SHELL
REVIEW_FILE="$REVIEW_FILE"
if [ -f "\$REVIEW_FILE" ]; then
    PENDING=\$(grep -c '"reviewed": null' "\$REVIEW_FILE" 2>/dev/null || echo 0)
    FLAGGED=\$(grep '"reviewed": null' "\$REVIEW_FILE" 2>/dev/null | grep -c '"external-unsanitized"' || echo 0)
    if [ "\$PENDING" -gt 0 ]; then
        echo "\${PENDING} pending promotions (\${FLAGGED} flagged external-unsanitized) — see .claude/ainous-roles/consolidator/promotion-review.jsonl"
    fi
fi
SHELL
    )

    # Must produce NO output (all entries are reviewed)
    [ -z "$result" ]
}

@test "PR-2c: Coordinator surface emits nothing when review file does not exist" {
    # Ensure file does not exist
    rm -f "$REVIEW_FILE"

    result=$(bash <<SHELL
REVIEW_FILE="$REVIEW_FILE"
if [ -f "\$REVIEW_FILE" ]; then
    PENDING=\$(grep -c '"reviewed": null' "\$REVIEW_FILE" 2>/dev/null || echo 0)
    FLAGGED=\$(grep '"reviewed": null' "\$REVIEW_FILE" 2>/dev/null | grep -c '"external-unsanitized"' || echo 0)
    if [ "\$PENDING" -gt 0 ]; then
        echo "\${PENDING} pending promotions (\${FLAGGED} flagged external-unsanitized) — see .claude/ainous-roles/consolidator/promotion-review.jsonl"
    fi
fi
SHELL
    )

    # Must produce NO output when file is absent
    [ -z "$result" ]
}

# ===========================================================================
# PR-3 — Veto path
# Source entry deleted → consolidator must skip promotion on the next cycle.
# Tested via a dry-run harness that checks existence of source excerpt before
# promoting.
# ===========================================================================

@test "PR-3a: Veto path — source entry present → promotion proceeds" {
    # Write the source file with the entry
    printf '%s\n' "$SOURCE_ENTRY" > "$TEAM_KNOWLEDGE"

    # Write a pending review entry referencing that source
    python3 - "$REVIEW_FILE" "$SOURCE_ENTRY" <<'PYEOF'
import json, pathlib, sys

review_file = pathlib.Path(sys.argv[1])
source_excerpt = sys.argv[2]
review_file.parent.mkdir(parents=True, exist_ok=True)

entry = {
    "timestamp": "2026-04-17T10:00:00Z",
    "consolidator_session": "2026-04-17",
    "target_file": ".claude/ainous-roles/developer/playbook.md",
    "target_entry_excerpt": "## run-bats-before-commit\nmaturity: shu",
    "source_carrier": "team-knowledge",
    "source_entries": [
        {
            "file": ".claude/ainous-roles/team-knowledge.md",
            "excerpt": source_excerpt,
            "provenance": {}
        }
    ],
    "upstream_chain": ["observed"],
    "reasoning": "team-knowledge fact promoted to strategy",
    "reviewed": None,
    "rejected": None,
}

with review_file.open("w") as f:
    f.write(json.dumps(entry) + "\n")
PYEOF

    # Dry-run harness: check if source excerpt still exists in source file
    # If yes → WOULD_PROMOTE; if no → SKIP_PROMOTION
    result=$(python3 - "$REVIEW_FILE" "$TEAM_KNOWLEDGE" <<'PYEOF'
import json, pathlib, sys

review_file = pathlib.Path(sys.argv[1])
entries = [json.loads(l) for l in review_file.read_text().splitlines() if l.strip()]

for entry in entries:
    if entry.get("reviewed") is not None:
        continue  # already reviewed, skip
    source_still_valid = True
    for se in entry.get("source_entries", []):
        source_path = pathlib.Path(sys.argv[2])
        if source_path.exists():
            source_text = source_path.read_text()
            if se["excerpt"] not in source_text:
                source_still_valid = False
                break
        else:
            source_still_valid = False
            break
    if source_still_valid:
        print("WOULD_PROMOTE")
    else:
        print("SKIP_PROMOTION")
PYEOF
    )

    [[ "$result" == "WOULD_PROMOTE" ]]
}

@test "PR-3b: Veto path — source entry deleted → consolidator skips promotion" {
    # Write the review entry referencing the source
    python3 - "$REVIEW_FILE" "$SOURCE_ENTRY" <<'PYEOF'
import json, pathlib, sys

review_file = pathlib.Path(sys.argv[1])
source_excerpt = sys.argv[2]
review_file.parent.mkdir(parents=True, exist_ok=True)

entry = {
    "timestamp": "2026-04-17T10:00:00Z",
    "consolidator_session": "2026-04-17",
    "target_file": ".claude/ainous-roles/developer/playbook.md",
    "target_entry_excerpt": "## run-bats-before-commit\nmaturity: shu",
    "source_carrier": "team-knowledge",
    "source_entries": [
        {
            "file": ".claude/ainous-roles/team-knowledge.md",
            "excerpt": source_excerpt,
            "provenance": {}
        }
    ],
    "upstream_chain": ["observed"],
    "reasoning": "team-knowledge fact promoted to strategy",
    "reviewed": None,
    "rejected": None,
}

with review_file.open("w") as f:
    f.write(json.dumps(entry) + "\n")
PYEOF

    # Source file does NOT exist (user deleted the entry / team-knowledge.md entry removed)
    rm -f "$TEAM_KNOWLEDGE"

    # Dry-run harness: source file absent → SKIP_PROMOTION
    result=$(python3 - "$REVIEW_FILE" "$TEAM_KNOWLEDGE" <<'PYEOF'
import json, pathlib, sys

review_file = pathlib.Path(sys.argv[1])
entries = [json.loads(l) for l in review_file.read_text().splitlines() if l.strip()]

for entry in entries:
    if entry.get("reviewed") is not None:
        continue
    source_still_valid = True
    for se in entry.get("source_entries", []):
        source_path = pathlib.Path(sys.argv[2])
        if source_path.exists():
            source_text = source_path.read_text()
            if se["excerpt"] not in source_text:
                source_still_valid = False
                break
        else:
            source_still_valid = False
            break
    if source_still_valid:
        print("WOULD_PROMOTE")
    else:
        print("SKIP_PROMOTION")
PYEOF
    )

    [[ "$result" == "SKIP_PROMOTION" ]]
}

@test "PR-3c: Veto path — source entry modified (excerpt no longer matches) → consolidator skips" {
    # Write the source file with a DIFFERENT entry (user modified it)
    printf 'Different content entirely\n' > "$TEAM_KNOWLEDGE"

    # Review entry still references the original excerpt
    python3 - "$REVIEW_FILE" "$SOURCE_ENTRY" <<'PYEOF'
import json, pathlib, sys

review_file = pathlib.Path(sys.argv[1])
source_excerpt = sys.argv[2]
review_file.parent.mkdir(parents=True, exist_ok=True)

entry = {
    "timestamp": "2026-04-17T10:00:00Z",
    "consolidator_session": "2026-04-17",
    "target_file": ".claude/ainous-roles/developer/playbook.md",
    "target_entry_excerpt": "## run-bats-before-commit\nmaturity: shu",
    "source_carrier": "team-knowledge",
    "source_entries": [
        {
            "file": ".claude/ainous-roles/team-knowledge.md",
            "excerpt": source_excerpt,
            "provenance": {}
        }
    ],
    "upstream_chain": ["observed"],
    "reasoning": "team-knowledge fact promoted to strategy",
    "reviewed": None,
    "rejected": None,
}

with review_file.open("w") as f:
    f.write(json.dumps(entry) + "\n")
PYEOF

    # Dry-run harness: source exists but excerpt no longer matches → SKIP_PROMOTION
    result=$(python3 - "$REVIEW_FILE" "$TEAM_KNOWLEDGE" <<'PYEOF'
import json, pathlib, sys

review_file = pathlib.Path(sys.argv[1])
entries = [json.loads(l) for l in review_file.read_text().splitlines() if l.strip()]

for entry in entries:
    if entry.get("reviewed") is not None:
        continue
    source_still_valid = True
    for se in entry.get("source_entries", []):
        source_path = pathlib.Path(sys.argv[2])
        if source_path.exists():
            source_text = source_path.read_text()
            if se["excerpt"] not in source_text:
                source_still_valid = False
                break
        else:
            source_still_valid = False
            break
    if source_still_valid:
        print("WOULD_PROMOTE")
    else:
        print("SKIP_PROMOTION")
PYEOF
    )

    [[ "$result" == "SKIP_PROMOTION" ]]
}

# ===========================================================================
# PR-4 — External-sourced entry with NO approval → consolidator SKIPS (blocked)
# ===========================================================================

@test "PR-4: External-sourced entry, no approval line -> SKIP (blocked)" {
    APPROVALS_FILE="$FAKE_PROJECT/.claude/ainous-roles/consolidator/promotion-approvals.md"
    CLASSIFIER="$FAKE_PROJECT/classifier.py"

    # Write classifier to temp script file (cannot use python3 /dev/stdin inside $() subshell)
    python3 - "$CLASSIFIER" <<'PYEOF'
import pathlib, sys, textwrap
src = textwrap.dedent("""
    import json, pathlib, datetime, sys
    EXTERNAL = frozenset(["external-unsanitized", "signal-hit", "signal", "user-corrections"])
    def classify_tier(entry):
        chain = set(entry.get("upstream_chain") or [])
        carrier = entry.get("source_carrier", "")
        if carrier in frozenset(["journal-compaction", "utility-update", "staleness-prune",
                       "maturity-shu-ha", "ri-archive"]):
            return "compaction"
        if chain & EXTERNAL or carrier in frozenset(["signal-hit", "user-corrections"]):
            return "external"
        distinct_roles = set(e.get("file", "").split("/")[2]
                          for e in entry.get("source_entries", [])
                          if e.get("file", "").startswith(".claude/ainous-roles/"))
        if carrier == "cross-role" or len(distinct_roles) >= 2:
            return "cross-role"
        return "cross-role"
    review_file = pathlib.Path(sys.argv[1])
    approvals_file = pathlib.Path(sys.argv[2])
    approvals = []
    if approvals_file.exists():
        for ln in approvals_file.read_text().splitlines():
            ln = ln.strip()
            if ln and not ln.startswith("#") and ln.startswith("{"):
                try:
                    approvals.append(json.loads(ln))
                except Exception:
                    pass
    consumed_keys = set((a["ref_timestamp"], a["ref_session"]) for a in approvals if "consumed_at" in a)
    now = datetime.datetime.utcnow()
    for ln in review_file.read_text().splitlines():
        ln = ln.strip()
        if not ln:
            continue
        entry = json.loads(ln)
        if entry.get("reviewed") is not None:
            continue
        key = (entry["timestamp"], entry["consolidator_session"])
        if key in consumed_keys:
            continue
        tier = classify_tier(entry)
        approved = any(a.get("decision") == "approved"
                       and a.get("ref_timestamp") == entry["timestamp"]
                       and a.get("ref_session") == entry["consolidator_session"]
                       for a in approvals)
        rejected = any(a.get("decision") == "rejected"
                       and a.get("ref_timestamp") == entry["timestamp"]
                       and a.get("ref_session") == entry["consolidator_session"]
                       for a in approvals)
        if tier == "compaction":
            print("APPLY")
        elif tier == "external":
            print("APPLY" if approved else "SKIP")
        elif tier == "cross-role":
            if rejected:
                print("SKIP")
            else:
                entry_time = datetime.datetime.strptime(entry["timestamp"], "%Y-%m-%dT%H:%M:%SZ")
                elapsed = (now - entry_time).total_seconds()
                print("APPLY" if elapsed >= 86400 else "SKIP")
""").strip()
pathlib.Path(sys.argv[1]).write_text(src + "\n")
PYEOF

    python3 - "$REVIEW_FILE" <<'PYEOF'
import json, pathlib, sys
review_file = pathlib.Path(sys.argv[1])
review_file.parent.mkdir(parents=True, exist_ok=True)
entry = {
    "timestamp": "2026-04-17T10:00:00Z",
    "consolidator_session": "2026-04-17",
    "target_file": ".claude/ainous-roles/coordinator/playbook.md",
    "target_entry_excerpt": "When signal reports trending tool, evaluate for adoption",
    "source_carrier": "signal-hit",
    "source_entries": [
        {"file": ".claude/ainous-roles/signal/findings.md",
         "excerpt": "HackerNews: tool X trending",
         "provenance": {"source": "external-unsanitized"}}
    ],
    "upstream_chain": ["external-unsanitized"],
    "reasoning": "signal-hit from external source",
    "reviewed": None,
    "rejected": None,
}
with review_file.open("w") as f:
    f.write(json.dumps(entry) + "\n")
PYEOF

    rm -f "$APPROVALS_FILE"
    result=$(python3 "$CLASSIFIER" "$REVIEW_FILE" "$APPROVALS_FILE")
    [[ "$result" == "SKIP" ]]
}

# ===========================================================================
# PR-5 — External-sourced entry WITH approval line → consolidator APPLIES
# ===========================================================================

@test "PR-5: External-sourced entry, approval line present -> APPLY" {
    APPROVALS_FILE="$FAKE_PROJECT/.claude/ainous-roles/consolidator/promotion-approvals.md"
    CLASSIFIER="$FAKE_PROJECT/classifier.py"

    python3 - "$CLASSIFIER" <<'PYEOF'
import pathlib, sys, textwrap
src = textwrap.dedent("""
    import json, pathlib, datetime, sys
    EXTERNAL = frozenset(["external-unsanitized", "signal-hit", "signal", "user-corrections"])
    def classify_tier(entry):
        chain = set(entry.get("upstream_chain") or [])
        carrier = entry.get("source_carrier", "")
        if carrier in frozenset(["journal-compaction", "utility-update", "staleness-prune",
                       "maturity-shu-ha", "ri-archive"]):
            return "compaction"
        if chain & EXTERNAL or carrier in frozenset(["signal-hit", "user-corrections"]):
            return "external"
        distinct_roles = set(e.get("file", "").split("/")[2]
                          for e in entry.get("source_entries", [])
                          if e.get("file", "").startswith(".claude/ainous-roles/"))
        if carrier == "cross-role" or len(distinct_roles) >= 2:
            return "cross-role"
        return "cross-role"
    review_file = pathlib.Path(sys.argv[1])
    approvals_file = pathlib.Path(sys.argv[2])
    approvals = []
    if approvals_file.exists():
        for ln in approvals_file.read_text().splitlines():
            ln = ln.strip()
            if ln and not ln.startswith("#") and ln.startswith("{"):
                try:
                    approvals.append(json.loads(ln))
                except Exception:
                    pass
    consumed_keys = set((a["ref_timestamp"], a["ref_session"]) for a in approvals if "consumed_at" in a)
    now = datetime.datetime.utcnow()
    for ln in review_file.read_text().splitlines():
        ln = ln.strip()
        if not ln:
            continue
        entry = json.loads(ln)
        if entry.get("reviewed") is not None:
            continue
        key = (entry["timestamp"], entry["consolidator_session"])
        if key in consumed_keys:
            continue
        tier = classify_tier(entry)
        approved = any(a.get("decision") == "approved"
                       and a.get("ref_timestamp") == entry["timestamp"]
                       and a.get("ref_session") == entry["consolidator_session"]
                       for a in approvals)
        rejected = any(a.get("decision") == "rejected"
                       and a.get("ref_timestamp") == entry["timestamp"]
                       and a.get("ref_session") == entry["consolidator_session"]
                       for a in approvals)
        if tier == "compaction":
            print("APPLY")
        elif tier == "external":
            print("APPLY" if approved else "SKIP")
        elif tier == "cross-role":
            if rejected:
                print("SKIP")
            else:
                entry_time = datetime.datetime.strptime(entry["timestamp"], "%Y-%m-%dT%H:%M:%SZ")
                elapsed = (now - entry_time).total_seconds()
                print("APPLY" if elapsed >= 86400 else "SKIP")
""").strip()
pathlib.Path(sys.argv[1]).write_text(src + "\n")
PYEOF

    python3 - "$REVIEW_FILE" <<'PYEOF'
import json, pathlib, sys
review_file = pathlib.Path(sys.argv[1])
review_file.parent.mkdir(parents=True, exist_ok=True)
entry = {
    "timestamp": "2026-04-17T10:00:00Z",
    "consolidator_session": "2026-04-17",
    "target_file": ".claude/ainous-roles/coordinator/playbook.md",
    "target_entry_excerpt": "When signal reports trending tool, evaluate for adoption",
    "source_carrier": "signal-hit",
    "source_entries": [
        {"file": ".claude/ainous-roles/signal/findings.md",
         "excerpt": "HackerNews: tool X trending",
         "provenance": {"source": "external-unsanitized"}}
    ],
    "upstream_chain": ["external-unsanitized"],
    "reasoning": "signal-hit from external source",
    "reviewed": None,
    "rejected": None,
}
with review_file.open("w") as f:
    f.write(json.dumps(entry) + "\n")
PYEOF

    python3 - "$APPROVALS_FILE" <<'PYEOF'
import json, pathlib, sys
approvals_file = pathlib.Path(sys.argv[1])
approvals_file.parent.mkdir(parents=True, exist_ok=True)
approval = {
    "ref_timestamp": "2026-04-17T10:00:00Z",
    "ref_session": "2026-04-17",
    "decision": "approved",
    "approved_at": "2026-04-17T14:00:00Z",
    "approved_by": "user",
}
with approvals_file.open("w") as f:
    f.write("# Promotion Approvals\n\n## approvals\n")
    f.write(json.dumps(approval) + "\n")
PYEOF

    result=$(python3 "$CLASSIFIER" "$REVIEW_FILE" "$APPROVALS_FILE")
    [[ "$result" == "APPLY" ]]
}

# ===========================================================================
# PR-6 — Cross-role entry, timestamp 25h old, no rejection → APPLIES (24h elapsed)
# ===========================================================================

@test "PR-6: Cross-role entry, 25h old, no rejection -> APPLY (24h elapsed)" {
    APPROVALS_FILE="$FAKE_PROJECT/.claude/ainous-roles/consolidator/promotion-approvals.md"
    CLASSIFIER="$FAKE_PROJECT/classifier.py"
    rm -f "$APPROVALS_FILE"

    python3 - "$CLASSIFIER" <<'PYEOF'
import pathlib, sys, textwrap
src = textwrap.dedent("""
    import json, pathlib, datetime, sys
    EXTERNAL = frozenset(["external-unsanitized", "signal-hit", "signal", "user-corrections"])
    def classify_tier(entry):
        chain = set(entry.get("upstream_chain") or [])
        carrier = entry.get("source_carrier", "")
        if carrier in frozenset(["journal-compaction", "utility-update", "staleness-prune",
                       "maturity-shu-ha", "ri-archive"]):
            return "compaction"
        if chain & EXTERNAL or carrier in frozenset(["signal-hit", "user-corrections"]):
            return "external"
        distinct_roles = set(e.get("file", "").split("/")[2]
                          for e in entry.get("source_entries", [])
                          if e.get("file", "").startswith(".claude/ainous-roles/"))
        if carrier == "cross-role" or len(distinct_roles) >= 2:
            return "cross-role"
        return "cross-role"
    review_file = pathlib.Path(sys.argv[1])
    approvals_file = pathlib.Path(sys.argv[2])
    approvals = []
    if approvals_file.exists():
        for ln in approvals_file.read_text().splitlines():
            ln = ln.strip()
            if ln and not ln.startswith("#") and ln.startswith("{"):
                try:
                    approvals.append(json.loads(ln))
                except Exception:
                    pass
    consumed_keys = set((a["ref_timestamp"], a["ref_session"]) for a in approvals if "consumed_at" in a)
    now = datetime.datetime.utcnow()
    for ln in review_file.read_text().splitlines():
        ln = ln.strip()
        if not ln:
            continue
        entry = json.loads(ln)
        if entry.get("reviewed") is not None:
            continue
        key = (entry["timestamp"], entry["consolidator_session"])
        if key in consumed_keys:
            continue
        tier = classify_tier(entry)
        approved = any(a.get("decision") == "approved"
                       and a.get("ref_timestamp") == entry["timestamp"]
                       and a.get("ref_session") == entry["consolidator_session"]
                       for a in approvals)
        rejected = any(a.get("decision") == "rejected"
                       and a.get("ref_timestamp") == entry["timestamp"]
                       and a.get("ref_session") == entry["consolidator_session"]
                       for a in approvals)
        if tier == "compaction":
            print("APPLY")
        elif tier == "external":
            print("APPLY" if approved else "SKIP")
        elif tier == "cross-role":
            if rejected:
                print("SKIP")
            else:
                entry_time = datetime.datetime.strptime(entry["timestamp"], "%Y-%m-%dT%H:%M:%SZ")
                elapsed = (now - entry_time).total_seconds()
                print("APPLY" if elapsed >= 86400 else "SKIP")
""").strip()
pathlib.Path(sys.argv[1]).write_text(src + "\n")
PYEOF

    python3 - "$REVIEW_FILE" <<'PYEOF'
import json, pathlib, datetime, sys
review_file = pathlib.Path(sys.argv[1])
review_file.parent.mkdir(parents=True, exist_ok=True)
old_ts = (datetime.datetime.utcnow() - datetime.timedelta(hours=25)).strftime("%Y-%m-%dT%H:%M:%SZ")
entry = {
    "timestamp": old_ts,
    "consolidator_session": "2026-04-16",
    "target_file": ".claude/ainous-roles/developer/playbook.md",
    "target_entry_excerpt": "Cross-role insight: tester and researcher both noted X",
    "source_carrier": "cross-role",
    "source_entries": [
        {"file": ".claude/ainous-roles/tester/journal.md", "excerpt": "insight A", "provenance": {}},
        {"file": ".claude/ainous-roles/researcher/journal.md", "excerpt": "insight A", "provenance": {}},
    ],
    "upstream_chain": ["observed"],
    "reasoning": "cross-role pattern from tester and researcher",
    "reviewed": None,
    "rejected": None,
}
with review_file.open("w") as f:
    f.write(json.dumps(entry) + "\n")
PYEOF

    result=$(python3 "$CLASSIFIER" "$REVIEW_FILE" "$APPROVALS_FILE")
    [[ "$result" == "APPLY" ]]
}

# ===========================================================================
# PR-7 — Cross-role entry, timestamp 25h old, rejection line present → SKIP
# ===========================================================================

@test "PR-7: Cross-role entry, 25h old, rejection line present -> SKIP" {
    APPROVALS_FILE="$FAKE_PROJECT/.claude/ainous-roles/consolidator/promotion-approvals.md"
    CLASSIFIER="$FAKE_PROJECT/classifier.py"

    python3 - "$CLASSIFIER" <<'PYEOF'
import pathlib, sys, textwrap
src = textwrap.dedent("""
    import json, pathlib, datetime, sys
    EXTERNAL = frozenset(["external-unsanitized", "signal-hit", "signal", "user-corrections"])
    def classify_tier(entry):
        chain = set(entry.get("upstream_chain") or [])
        carrier = entry.get("source_carrier", "")
        if carrier in frozenset(["journal-compaction", "utility-update", "staleness-prune",
                       "maturity-shu-ha", "ri-archive"]):
            return "compaction"
        if chain & EXTERNAL or carrier in frozenset(["signal-hit", "user-corrections"]):
            return "external"
        distinct_roles = set(e.get("file", "").split("/")[2]
                          for e in entry.get("source_entries", [])
                          if e.get("file", "").startswith(".claude/ainous-roles/"))
        if carrier == "cross-role" or len(distinct_roles) >= 2:
            return "cross-role"
        return "cross-role"
    review_file = pathlib.Path(sys.argv[1])
    approvals_file = pathlib.Path(sys.argv[2])
    approvals = []
    if approvals_file.exists():
        for ln in approvals_file.read_text().splitlines():
            ln = ln.strip()
            if ln and not ln.startswith("#") and ln.startswith("{"):
                try:
                    approvals.append(json.loads(ln))
                except Exception:
                    pass
    consumed_keys = set((a["ref_timestamp"], a["ref_session"]) for a in approvals if "consumed_at" in a)
    now = datetime.datetime.utcnow()
    for ln in review_file.read_text().splitlines():
        ln = ln.strip()
        if not ln:
            continue
        entry = json.loads(ln)
        if entry.get("reviewed") is not None:
            continue
        key = (entry["timestamp"], entry["consolidator_session"])
        if key in consumed_keys:
            continue
        tier = classify_tier(entry)
        approved = any(a.get("decision") == "approved"
                       and a.get("ref_timestamp") == entry["timestamp"]
                       and a.get("ref_session") == entry["consolidator_session"]
                       for a in approvals)
        rejected = any(a.get("decision") == "rejected"
                       and a.get("ref_timestamp") == entry["timestamp"]
                       and a.get("ref_session") == entry["consolidator_session"]
                       for a in approvals)
        if tier == "compaction":
            print("APPLY")
        elif tier == "external":
            print("APPLY" if approved else "SKIP")
        elif tier == "cross-role":
            if rejected:
                print("SKIP")
            else:
                entry_time = datetime.datetime.strptime(entry["timestamp"], "%Y-%m-%dT%H:%M:%SZ")
                elapsed = (now - entry_time).total_seconds()
                print("APPLY" if elapsed >= 86400 else "SKIP")
""").strip()
pathlib.Path(sys.argv[1]).write_text(src + "\n")
PYEOF

    python3 - "$REVIEW_FILE" <<'PYEOF'
import json, pathlib, datetime, sys
review_file = pathlib.Path(sys.argv[1])
review_file.parent.mkdir(parents=True, exist_ok=True)
old_ts = (datetime.datetime.utcnow() - datetime.timedelta(hours=25)).strftime("%Y-%m-%dT%H:%M:%SZ")
entry = {
    "timestamp": old_ts,
    "consolidator_session": "2026-04-16",
    "target_file": ".claude/ainous-roles/developer/playbook.md",
    "target_entry_excerpt": "Cross-role insight: tester and researcher both noted X",
    "source_carrier": "cross-role",
    "source_entries": [
        {"file": ".claude/ainous-roles/tester/journal.md", "excerpt": "insight A", "provenance": {}},
        {"file": ".claude/ainous-roles/researcher/journal.md", "excerpt": "insight A", "provenance": {}},
    ],
    "upstream_chain": ["observed"],
    "reasoning": "cross-role pattern from tester and researcher",
    "reviewed": None,
    "rejected": None,
}
with review_file.open("w") as f:
    f.write(json.dumps(entry) + "\n")
PYEOF

    python3 - "$APPROVALS_FILE" "$REVIEW_FILE" <<'PYEOF'
import json, pathlib, sys
approvals_file = pathlib.Path(sys.argv[1])
approvals_file.parent.mkdir(parents=True, exist_ok=True)
review_file = pathlib.Path(sys.argv[2])
entry = json.loads(review_file.read_text().strip().splitlines()[0])
rejection = {
    "ref_timestamp": entry["timestamp"],
    "ref_session": entry["consolidator_session"],
    "decision": "rejected",
    "approved_at": "2026-04-17T12:00:00Z",
    "approved_by": "user",
}
with approvals_file.open("w") as f:
    f.write("# Promotion Approvals\n\n## approvals\n")
    f.write(json.dumps(rejection) + "\n")
PYEOF

    result=$(python3 "$CLASSIFIER" "$REVIEW_FILE" "$APPROVALS_FILE")
    [[ "$result" == "SKIP" ]]
}

# ===========================================================================
# PR-8 — Compaction entry, no approval → APPLIES unconditionally
# ===========================================================================

@test "PR-8: Compaction entry, no approval -> APPLY (compaction is advisory, unconditional)" {
    APPROVALS_FILE="$FAKE_PROJECT/.claude/ainous-roles/consolidator/promotion-approvals.md"
    CLASSIFIER="$FAKE_PROJECT/classifier.py"
    rm -f "$APPROVALS_FILE"

    python3 - "$CLASSIFIER" <<'PYEOF'
import pathlib, sys, textwrap
src = textwrap.dedent("""
    import json, pathlib, datetime, sys
    EXTERNAL = frozenset(["external-unsanitized", "signal-hit", "signal", "user-corrections"])
    def classify_tier(entry):
        chain = set(entry.get("upstream_chain") or [])
        carrier = entry.get("source_carrier", "")
        if carrier in frozenset(["journal-compaction", "utility-update", "staleness-prune",
                       "maturity-shu-ha", "ri-archive"]):
            return "compaction"
        if chain & EXTERNAL or carrier in frozenset(["signal-hit", "user-corrections"]):
            return "external"
        distinct_roles = set(e.get("file", "").split("/")[2]
                          for e in entry.get("source_entries", [])
                          if e.get("file", "").startswith(".claude/ainous-roles/"))
        if carrier == "cross-role" or len(distinct_roles) >= 2:
            return "cross-role"
        return "cross-role"
    review_file = pathlib.Path(sys.argv[1])
    approvals_file = pathlib.Path(sys.argv[2])
    approvals = []
    if approvals_file.exists():
        for ln in approvals_file.read_text().splitlines():
            ln = ln.strip()
            if ln and not ln.startswith("#") and ln.startswith("{"):
                try:
                    approvals.append(json.loads(ln))
                except Exception:
                    pass
    consumed_keys = set((a["ref_timestamp"], a["ref_session"]) for a in approvals if "consumed_at" in a)
    now = datetime.datetime.utcnow()
    for ln in review_file.read_text().splitlines():
        ln = ln.strip()
        if not ln:
            continue
        entry = json.loads(ln)
        if entry.get("reviewed") is not None:
            continue
        key = (entry["timestamp"], entry["consolidator_session"])
        if key in consumed_keys:
            continue
        tier = classify_tier(entry)
        approved = any(a.get("decision") == "approved"
                       and a.get("ref_timestamp") == entry["timestamp"]
                       and a.get("ref_session") == entry["consolidator_session"]
                       for a in approvals)
        rejected = any(a.get("decision") == "rejected"
                       and a.get("ref_timestamp") == entry["timestamp"]
                       and a.get("ref_session") == entry["consolidator_session"]
                       for a in approvals)
        if tier == "compaction":
            print("APPLY")
        elif tier == "external":
            print("APPLY" if approved else "SKIP")
        elif tier == "cross-role":
            if rejected:
                print("SKIP")
            else:
                entry_time = datetime.datetime.strptime(entry["timestamp"], "%Y-%m-%dT%H:%M:%SZ")
                elapsed = (now - entry_time).total_seconds()
                print("APPLY" if elapsed >= 86400 else "SKIP")
""").strip()
pathlib.Path(sys.argv[1]).write_text(src + "\n")
PYEOF

    python3 - "$REVIEW_FILE" <<'PYEOF'
import json, pathlib, sys
review_file = pathlib.Path(sys.argv[1])
review_file.parent.mkdir(parents=True, exist_ok=True)
entry = {
    "timestamp": "2026-04-17T10:00:00Z",
    "consolidator_session": "2026-04-17",
    "target_file": ".claude/ainous-roles/developer/playbook.md",
    "target_entry_excerpt": "Compacted compiled truth rewrite",
    "source_carrier": "journal-compaction",
    "source_entries": [],
    "upstream_chain": ["internal"],
    "reasoning": "journal compaction",
    "reviewed": None,
    "rejected": None,
}
with review_file.open("w") as f:
    f.write(json.dumps(entry) + "\n")
PYEOF

    result=$(python3 "$CLASSIFIER" "$REVIEW_FILE" "$APPROVALS_FILE")
    [[ "$result" == "APPLY" ]]
}

# ===========================================================================
# PR-9 — Coordinator v3 surface with tier breakdown
# 2 external-blocking + 1 cross-role-waiting (within 24h) → correct 2-line format
# ===========================================================================

@test "PR-9: Coordinator v3 surface -- 2 external-blocking + 1 cross-role-waiting -> correct format" {
    APPROVALS_FILE="$FAKE_PROJECT/.claude/ainous-roles/consolidator/promotion-approvals.md"
    SURFACE="$FAKE_PROJECT/surface.py"
    rm -f "$APPROVALS_FILE"

    python3 - "$SURFACE" <<'PYEOF'
import pathlib, sys, textwrap
src = textwrap.dedent("""
    import json, pathlib, datetime, sys
    EXTERNAL = frozenset(["external-unsanitized", "signal-hit", "signal", "user-corrections"])
    def classify_tier(entry):
        chain = set(entry.get("upstream_chain") or [])
        carrier = entry.get("source_carrier", "")
        if carrier in frozenset(["journal-compaction", "utility-update", "staleness-prune",
                       "maturity-shu-ha", "ri-archive"]):
            return "awaiting-review"
        if chain & EXTERNAL or carrier in frozenset(["signal-hit", "user-corrections"]):
            return "external-blocking"
        distinct_roles = set(e.get("file", "").split("/")[2]
                          for e in entry.get("source_entries", [])
                          if e.get("file", "").startswith(".claude/ainous-roles/"))
        if carrier == "cross-role" or len(distinct_roles) >= 2:
            return "cross-role-waiting"
        return "cross-role-waiting"
    review_file = pathlib.Path(sys.argv[1])
    approvals_file = pathlib.Path(sys.argv[2])
    consumed_keys = set()
    if approvals_file.exists():
        for ln in approvals_file.read_text().splitlines():
            ln = ln.strip()
            if ln and not ln.startswith("#") and ln.startswith("{"):
                try:
                    a = json.loads(ln)
                    if "consumed_at" in a:
                        consumed_keys.add((a["ref_timestamp"], a["ref_session"]))
                except Exception:
                    pass
    ext_count = cross_count = compaction_count = 0
    now = datetime.datetime.utcnow()
    for ln in review_file.read_text().splitlines():
        ln = ln.strip()
        if not ln:
            continue
        entry = json.loads(ln)
        if entry.get("reviewed") is not None:
            continue
        key = (entry["timestamp"], entry["consolidator_session"])
        if key in consumed_keys:
            continue
        tier = classify_tier(entry)
        entry_time = datetime.datetime.strptime(entry["timestamp"], "%Y-%m-%dT%H:%M:%SZ")
        if tier == "external-blocking":
            ext_count += 1
        elif tier == "cross-role-waiting":
            elapsed = (now - entry_time).total_seconds()
            if elapsed < 86400:
                cross_count += 1
        elif tier == "awaiting-review":
            compaction_count += 1
    total = ext_count + cross_count + compaction_count
    if total > 0:
        print(str(total) + " pending promotions (" + str(ext_count) + " external-blocking, " + str(cross_count) + " cross-role-waiting, " + str(compaction_count) + " awaiting-review) -- see .claude/ainous-roles/consolidator/promotion-review.jsonl")
        if ext_count > 0:
            print("EXTERNAL-BLOCKING: " + str(ext_count) + " promotions require approval -- edit .claude/ainous-roles/consolidator/promotion-approvals.md")
""").strip()
pathlib.Path(sys.argv[1]).write_text(src + "\n")
PYEOF

    python3 - "$REVIEW_FILE" <<'PYEOF'
import json, pathlib, datetime, sys
review_file = pathlib.Path(sys.argv[1])
review_file.parent.mkdir(parents=True, exist_ok=True)
now = datetime.datetime.utcnow()
recent_ts = (now - datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
entries = [
    {
        "timestamp": "2026-04-17T08:00:00Z",
        "consolidator_session": "2026-04-17",
        "target_file": ".claude/ainous-roles/coordinator/playbook.md",
        "target_entry_excerpt": "signal strategy A",
        "source_carrier": "signal-hit",
        "source_entries": [],
        "upstream_chain": ["external-unsanitized"],
        "reasoning": "external signal",
        "reviewed": None,
        "rejected": None,
    },
    {
        "timestamp": "2026-04-17T09:00:00Z",
        "consolidator_session": "2026-04-17",
        "target_file": ".claude/ainous-roles/developer/playbook.md",
        "target_entry_excerpt": "user-learned strategy B",
        "source_carrier": "user-corrections",
        "source_entries": [],
        "upstream_chain": ["user-corrections"],
        "reasoning": "user correction",
        "reviewed": None,
        "rejected": None,
    },
    {
        "timestamp": recent_ts,
        "consolidator_session": "2026-04-17",
        "target_file": ".claude/ainous-roles/tester/playbook.md",
        "target_entry_excerpt": "cross-role insight C",
        "source_carrier": "cross-role",
        "source_entries": [
            {"file": ".claude/ainous-roles/tester/journal.md", "excerpt": "x", "provenance": {}},
            {"file": ".claude/ainous-roles/researcher/journal.md", "excerpt": "x", "provenance": {}},
        ],
        "upstream_chain": ["observed"],
        "reasoning": "cross-role tester+researcher",
        "reviewed": None,
        "rejected": None,
    },
]
with review_file.open("w") as f:
    for e in entries:
        f.write(json.dumps(e) + "\n")
PYEOF

    result=$(python3 "$SURFACE" "$REVIEW_FILE" "$APPROVALS_FILE")

    # Must produce exactly 2 lines
    line_count=$(echo "$result" | grep -c .)
    [ "$line_count" -eq 2 ]

    # First line: correct counts
    first_line=$(echo "$result" | head -1)
    [[ "$first_line" == *"3 pending promotions"* ]]
    [[ "$first_line" == *"2 external-blocking"* ]]
    [[ "$first_line" == *"1 cross-role-waiting"* ]]
    [[ "$first_line" == *"0 awaiting-review"* ]]

    # Second line: EXTERNAL-BLOCKING action line
    second_line=$(echo "$result" | tail -1)
    [[ "$second_line" == "EXTERNAL-BLOCKING:"* ]]
    [[ "$second_line" == *"promotion-approvals.md"* ]]
}
