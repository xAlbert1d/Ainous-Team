#!/usr/bin/env python3
# gen-skill-index.py — generate the `skills` block of agents/capabilities/index.json
#
# Generated — DO NOT edit the skills block by hand; regenerate after any card/SKILL.md
# change (Gate 7 enforces).
#
# Walk skills/*/SKILL.md: parse frontmatter name, description, invocable (default true).
# Walk agents/capabilities/*.json (skip index.json): build per-skill owning_roles,
# default_for, and triggers (union of `when` phrases from conditional_skills entries).
#
# Emit a `skills` object keyed by skill name, SORTED keys (LC_ALL=C deterministic).
# Each entry: {description, triggers[], owning_roles[], default_for[], invocable}.
#
# Modes:
#   default    — rewrite ONLY the `skills` block of agents/capabilities/index.json
#   --stdout   — print canonical skills JSON, write nothing
#   --check    — exit nonzero if committed differs from fresh (exit 2 on drift)
#
# Exit codes:
#   0  — ok
#   1  — no skills found or malformed input
#   2  — drift detected (--check mode only)

import json
import os
import re
import sys
import argparse
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PLUGIN_ROOT = os.path.dirname(SCRIPT_DIR)
SKILLS_DIR = os.path.join(PLUGIN_ROOT, "skills")
CAPS_DIR = os.path.join(PLUGIN_ROOT, "agents", "capabilities")
INDEX_PATH = os.path.join(CAPS_DIR, "index.json")


def parse_frontmatter(path):
    """Parse YAML-style frontmatter from a SKILL.md file.
    Returns a dict with the parsed key/value pairs, or empty dict on failure.
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            content = fh.read()
    except OSError:
        return {}

    # Frontmatter is between the first two `---` delimiters
    if not content.startswith("---"):
        return {}
    end = content.find("---", 3)
    if end == -1:
        return {}
    fm_text = content[3:end].strip()

    result = {}
    for line in fm_text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" in line:
            key, _, value = line.partition(":")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            # Parse booleans
            if value.lower() == "true":
                result[key] = True
            elif value.lower() == "false":
                result[key] = False
            else:
                result[key] = value
    return result


def tokenize_when(when_phrase):
    """Extract keyword tokens from a conditional_skills `when` string.

    Handles patterns like:
      "keywords include X, Y, Z"
      "task type is cleanup or technical debt"
      "keywords include API, endpoint, interface, contract"
    Returns a list of non-trivial token strings.
    """
    if not when_phrase:
        return []

    # Strip a leading "keywords include" prefix and split on commas/semicolons
    phrase = re.sub(r"^keywords include\s+", "", when_phrase, flags=re.IGNORECASE)
    # Also handle "keywords include X and Y" patterns
    phrase = re.sub(r"\bkeywords\b", "", phrase, flags=re.IGNORECASE)
    phrase = re.sub(r"\binclude\b", "", phrase, flags=re.IGNORECASE)
    phrase = phrase.strip()

    # Split on comma or semicolon
    parts = re.split(r"[,;]", phrase)
    tokens = []
    for part in parts:
        part = part.strip()
        if part:
            tokens.append(part)
    return tokens


def collect_skills():
    """Walk skills/*/SKILL.md and collect skill metadata.
    Returns dict keyed by skill name.
    """
    skills = {}
    if not os.path.isdir(SKILLS_DIR):
        print(
            f"gen-skill-index.py: ERROR — skills directory not found: {SKILLS_DIR}",
            file=sys.stderr,
        )
        return {}

    for entry in sorted(os.listdir(SKILLS_DIR)):
        skill_dir = os.path.join(SKILLS_DIR, entry)
        skill_md = os.path.join(skill_dir, "SKILL.md")
        if not os.path.isdir(skill_dir) or not os.path.isfile(skill_md):
            continue

        fm = parse_frontmatter(skill_md)
        name = fm.get("name", "").strip()
        description = fm.get("description", "").strip()
        invocable = fm.get("invocable", True)  # default true if absent

        if not name:
            print(
                f"gen-skill-index.py: WARNING — no `name` in frontmatter: {skill_md}",
                file=sys.stderr,
            )
            continue

        skills[name] = {
            "description": description,
            "triggers": [],
            "owning_roles": [],
            "default_for": [],
            "invocable": invocable,
        }

    return skills


def enrich_from_cards(skills):
    """Walk agents/capabilities/*.json (skip index.json) and populate
    owning_roles, default_for, and triggers for each skill.
    """
    if not os.path.isdir(CAPS_DIR):
        print(
            f"gen-skill-index.py: ERROR — capabilities directory not found: {CAPS_DIR}",
            file=sys.stderr,
        )
        return

    for fname in sorted(os.listdir(CAPS_DIR)):
        if not fname.endswith(".json") or fname == "index.json":
            continue
        card_path = os.path.join(CAPS_DIR, fname)
        try:
            with open(card_path, "r", encoding="utf-8") as fh:
                card = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            print(
                f"gen-skill-index.py: ERROR — could not parse {card_path}: {exc}",
                file=sys.stderr,
            )
            continue

        role = card.get("role", fname.replace(".json", ""))
        default_skills = card.get("default_skills", [])
        conditional_skills = card.get("conditional_skills", [])

        # default_skills → owning_roles + default_for
        for skill_name in default_skills:
            if skill_name in skills:
                entry = skills[skill_name]
                if role not in entry["owning_roles"]:
                    entry["owning_roles"].append(role)
                if role not in entry["default_for"]:
                    entry["default_for"].append(role)

        # conditional_skills → owning_roles + triggers
        for cs in conditional_skills:
            skill_name = cs.get("skill", "")
            when_phrase = cs.get("when", "")
            if skill_name not in skills:
                continue
            entry = skills[skill_name]
            if role not in entry["owning_roles"]:
                entry["owning_roles"].append(role)
            # Tokenize the `when` phrase and add unique tokens to triggers
            for token in tokenize_when(when_phrase):
                if token not in entry["triggers"]:
                    entry["triggers"].append(token)


def build_sorted_skills(skills):
    """Return a dict with LC_ALL=C sorted keys."""
    return dict(sorted(skills.items(), key=lambda kv: kv[0]))


def skills_to_json_str(sorted_skills):
    """Render skills dict to a canonical JSON string (2-space indent)."""
    return json.dumps(sorted_skills, indent=2, ensure_ascii=False)


def rewrite_index(sorted_skills):
    """Read index.json, replace (or add) the `skills` block, write back.
    Preserves all other top-level keys.
    """
    if not os.path.isfile(INDEX_PATH):
        print(
            f"gen-skill-index.py: ERROR — index.json not found: {INDEX_PATH}",
            file=sys.stderr,
        )
        sys.exit(1)

    with open(INDEX_PATH, "r", encoding="utf-8") as fh:
        index = json.load(fh)

    index["skills"] = sorted_skills

    with open(INDEX_PATH, "w", encoding="utf-8") as fh:
        json.dump(index, fh, indent=2, ensure_ascii=False)
        fh.write("\n")

    print(
        f"gen-skill-index.py: wrote {len(sorted_skills)} skill entries to {INDEX_PATH}"
    )


def check_drift(sorted_skills):
    """Compare committed index.json skills block against freshly generated.
    Exit 2 on drift, 0 if current.
    """
    if not os.path.isfile(INDEX_PATH):
        print(
            f"gen-skill-index.py: ERROR — index.json not found: {INDEX_PATH}",
            file=sys.stderr,
        )
        sys.exit(1)

    with open(INDEX_PATH, "r", encoding="utf-8") as fh:
        committed = json.load(fh)

    committed_skills = committed.get("skills", {})

    if committed_skills != sorted_skills:
        print(
            "gen-skill-index.py: DRIFT — committed skills block differs from freshly generated.",
            file=sys.stderr,
        )
        print(
            "  Regenerate with: python3 scripts/gen-skill-index.py",
            file=sys.stderr,
        )
        sys.exit(2)

    print("gen-skill-index.py: OK — committed skills block is current.")
    sys.exit(0)


def main():
    parser = argparse.ArgumentParser(
        description="Generate the skills block of agents/capabilities/index.json"
    )
    parser.add_argument(
        "--stdout",
        action="store_true",
        help="Print canonical skills JSON to stdout; write nothing",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit nonzero if committed index.json skills block differs from fresh",
    )
    args = parser.parse_args()

    skills = collect_skills()
    if not skills:
        print(
            "gen-skill-index.py: ERROR — no skills found in skills/ directory",
            file=sys.stderr,
        )
        sys.exit(1)

    enrich_from_cards(skills)
    sorted_skills = build_sorted_skills(skills)

    if args.stdout:
        print(skills_to_json_str(sorted_skills))
        sys.exit(0)

    if args.check:
        check_drift(sorted_skills)
        # check_drift calls sys.exit internally
        return

    # Default: rewrite skills block in index.json
    rewrite_index(sorted_skills)


if __name__ == "__main__":
    main()
