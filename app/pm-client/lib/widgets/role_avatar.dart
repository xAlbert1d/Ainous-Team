import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// RoleAvatar — 48 px color chip with role initial.
//
// Color is derived deterministically from the role name so it is rename-proof
// and requires no per-role configuration. The same derivation is used by
// RoleMemberCard and can be reused by any future widget needing a role color.
//
// Advisory-only (NAK-4): display-only widget, no onTap, no write path.
// ---------------------------------------------------------------------------

/// 48 px circular chip showing a role color and its first character.
///
/// Color is hash-derived from [role] for rename-proof visual identity.
/// Size can be overridden via [size] for compact uses.
class RoleAvatar extends StatelessWidget {
  // advisory-only (NAK-4)
  const RoleAvatar({
    super.key,
    required this.role,
    this.size = 48.0,
  });

  /// Role identifier string, e.g. "developer".
  final String role;

  /// Diameter of the circular chip in logical pixels. Defaults to 48.
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = roleColor(role);
    final initial = role.isNotEmpty ? role[0].toUpperCase() : '?';
    final fontSize = size * 0.4;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withAlpha(200),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          height: 1.0,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hash-derived role color — exported so other widgets stay in sync.
// ---------------------------------------------------------------------------

/// Deterministic color from [role] name using HSL hue hash.
///
/// Saturation and lightness are fixed so every derived color is visually
/// distinct and legible. The hue is derived from a simple string hash so
/// role name changes automatically shift the color (rename-proof).
Color roleColor(String role) {
  if (role.isEmpty) return const Color(0xFF9E9E9E); // grey fallback

  // Simple but stable hash: sum of char codes with position weighting.
  int hash = 0;
  for (int i = 0; i < role.length; i++) {
    hash = (hash * 31 + role.codeUnitAt(i)) & 0x7FFFFFFF;
  }

  // Map hash to hue in [0, 360).
  final hue = (hash % 360).toDouble();

  // Fixed saturation + lightness for consistent legibility across roles.
  return HSLColor.fromAHSL(1.0, hue, 0.60, 0.40).toColor();
}

/// Lighter tint of [roleColor] for use as a card background.
Color roleColorLight(String role) {
  if (role.isEmpty) return const Color(0xFFF5F5F5);
  final base = roleColor(role);
  // Blend toward white — keeps the card background subtle.
  return Color.alphaBlend(base.withAlpha(30), Colors.white);
}

/// Returns a hue angle (0–359) for the given role. Used for angle-based
/// computations (e.g. determining text contrast).
double roleHue(String role) {
  if (role.isEmpty) return 0.0;
  int hash = 0;
  for (int i = 0; i < role.length; i++) {
    hash = (hash * 31 + role.codeUnitAt(i)) & 0x7FFFFFFF;
  }
  return (hash % 360).toDouble();
}
