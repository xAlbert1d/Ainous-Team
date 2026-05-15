#!/usr/bin/env python3
"""
_hmac_common.py — Canonical HMAC helpers for the write-proxy protocol.

This module is the single source of truth for HMAC computation. Both
hooks/write-proxy (verification side) and teammates (computation side)
must derive their formula from here — they cannot disagree.

Protocol note: nonce_hex is decoded via bytes.fromhex(), NOT .encode().
This distinction historically caused mismatch (64 ASCII bytes vs 32 raw bytes).
"""
import hmac as _hmac
import hashlib
import re
import sys

MAGIC_MARKER = "<!-- WRITE-PROXY-ENVELOPE v1 -->"


def envelope_body_for_hmac(message: str) -> str:
    """Extract envelope body (everything after magic marker, excluding hmac line).

    Strips the MAGIC_MARKER prefix and any `hmac:` line that appears in the
    YAML frontmatter (between the opening '---' and the closing '---' delimiter).
    Lines with 'hmac:' in the body content section are NOT stripped — this
    prevents an attacker-controlled body line starting with 'hmac:' from
    bypassing HMAC integrity (v5.7.0 Item 6 fix).

    Body-format invariant: envelope structure is:
        MAGIC_MARKER
        ---
        <frontmatter key: value pairs, including optional hmac: line>
        ---
        <content body — arbitrary text, never stripped>
    """
    body = message[len(MAGIC_MARKER):].lstrip('\n')
    lines = body.splitlines(keepends=True)

    # Find the frontmatter boundary: first line must be '---\n', then find closing '---'
    # If frontmatter is absent or malformed, no stripping is done (fail-safe).
    filtered = []
    in_frontmatter = False
    frontmatter_closed = False

    for i, line in enumerate(lines):
        stripped = line.rstrip('\n').rstrip('\r')
        if i == 0 and stripped == '---':
            in_frontmatter = True
            filtered.append(line)
            continue
        if in_frontmatter and not frontmatter_closed:
            if stripped == '---':
                # Closing delimiter — end of frontmatter
                frontmatter_closed = True
                filtered.append(line)
            elif re.match(r'^hmac:\s*', line):
                # Suppress hmac: line only within frontmatter
                pass
            else:
                filtered.append(line)
        else:
            # Body content — append verbatim, never strip
            filtered.append(line)

    return ''.join(filtered)


def compute_envelope_hmac(body: str, nonce_hex: str) -> str:
    """Compute HMAC-SHA256 of body using nonce_hex as key.

    Args:
        body: Envelope body string (output of envelope_body_for_hmac).
        nonce_hex: 64-character hex string representing 32 raw key bytes.

    Returns:
        Hex digest string.

    Raises:
        ValueError: If nonce_hex is not valid hex.
    """
    key = bytes.fromhex(nonce_hex)  # 32 raw bytes — NOT nonce_hex.encode()
    return _hmac.new(key, body.encode('utf-8'), hashlib.sha256).hexdigest()


if __name__ == '__main__':
    # CLI usage:
    #   python3 hooks/_hmac_common.py <nonce_hex> <<< "<full envelope text>"
    # Reads envelope from stdin, prints hex HMAC to stdout.
    # Exits 0 on success, 2 on any error.
    if len(sys.argv) != 2:
        print(f"usage: python3 {sys.argv[0]} <nonce_hex>", file=sys.stderr)
        sys.exit(2)

    nonce_hex = sys.argv[1]

    try:
        bytes.fromhex(nonce_hex)
    except ValueError as exc:
        print(f"error: invalid nonce_hex — {exc}", file=sys.stderr)
        sys.exit(2)

    envelope_text = sys.stdin.read()

    if MAGIC_MARKER not in envelope_text:
        print(f"error: missing magic marker '{MAGIC_MARKER}'", file=sys.stderr)
        sys.exit(2)

    try:
        body = envelope_body_for_hmac(envelope_text)
        result = compute_envelope_hmac(body, nonce_hex)
        print(result)
        sys.exit(0)
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(2)
