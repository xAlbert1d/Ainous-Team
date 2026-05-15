import 'package:flutter/material.dart';

import '../models/role_capability.dart';
import '../models/role_pulse.dart';
import 'pulse_indicator.dart';
import 'role_avatar.dart';

// ---------------------------------------------------------------------------
// RoleMemberCard — grid card for a single role on TeamPage.
//
// Displays: RoleAvatar, role name, description, PulseIndicator.
// Tap: opens a stub drawer ("Member Detail — sub-phase 4").
//
// Card is display-only per NAK-4. The drawer stub produces no write path.
// Advisory-only (NAK-4): onTap opens a display-only drawer; no state mutation.
// ---------------------------------------------------------------------------

/// Card representing one persistent role.
///
/// Shows [RoleAvatar], name, description, and a [PulseIndicator].
/// Tapping the card opens a stub drawer (Member Detail comes in sub-phase 4).
class RoleMemberCard extends StatelessWidget {
  // advisory-only (NAK-4)
  const RoleMemberCard({
    super.key,
    required this.capability,
    required this.pulse,
  });

  /// Role capability data — name, description, skills.
  final RoleCapability capability;

  /// Current pulse state derived from [rolePulseProvider].
  final RolePulse pulse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final color = roleColor(capability.role);

    return Card(
      elevation: 1,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // advisory-only (NAK-4) — tap opens display-only drawer, no mutation.
        onTap: () => _openStubDrawer(context),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row: avatar + pulse indicator
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RoleAvatar(role: capability.role),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: PulseIndicator(pulse: pulse),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Role name
              Text(
                capability.role,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              // Description
              Text(
                capability.description ?? 'No description available.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurface.withAlpha(160),
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),
              // Top-3 skills as mini chips (if available)
              if (capability.defaultSkills.isNotEmpty)
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final skill
                        in capability.defaultSkills.take(3))
                      _SkillChip(skill: skill, roleColor: color),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens a stub drawer — Member Detail content ships in sub-phase 4.
  void _openStubDrawer(BuildContext context) {
    // advisory-only (NAK-4): drawer is display-only, no write path.
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Member Detail',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (ctx, _, __) {
        return Align(
          alignment: Alignment.centerRight,
          child: _MemberDetailStubDrawer(role: capability.role),
        );
      },
      transitionBuilder: (ctx, anim, _, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
          child: child,
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Stub drawer — placeholder for sub-phase 4 Member Detail content.
// ---------------------------------------------------------------------------

class _MemberDetailStubDrawer extends StatelessWidget {
  const _MemberDetailStubDrawer({required this.role});
  final String role;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final color = roleColor(role);
    final initial = role.isNotEmpty ? role[0].toUpperCase() : '?';

    return Material(
      elevation: 8,
      child: Container(
        width: 360,
        height: double.infinity,
        color: colorScheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header bar with role color accent
            Container(
              color: color.withAlpha(30),
              padding: const EdgeInsets.fromLTRB(16, 48, 16, 16),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: color.withAlpha(200),
                    child: Text(
                      initial,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 20,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      role,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.person_outline,
                        size: 64,
                        color: colorScheme.outline,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Member Detail — sub-phase 4',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: colorScheme.onSurface.withAlpha(160),
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Playbook, Journal, Learnings, and Sessions\n'
                        'tabs will be available in sub-phase 4.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurface.withAlpha(100),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Skill chip — compact display for a skill name on the card.
// ---------------------------------------------------------------------------

class _SkillChip extends StatelessWidget {
  const _SkillChip({required this.skill, required this.roleColor});
  final String skill;
  final Color roleColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: roleColor.withAlpha(25),
        border: Border.all(color: roleColor.withAlpha(80)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        skill,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: roleColor,
              fontSize: 10,
            ),
      ),
    );
  }
}
