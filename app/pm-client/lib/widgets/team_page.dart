import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/role_capability.dart';
import '../models/role_pulse.dart';
import '../providers/role_catalog_provider.dart';
import '../providers/role_pulse_provider.dart';
import 'role_member_card.dart';

// ---------------------------------------------------------------------------
// TeamPage — grid of role member cards.
//
// Data: roleCatalogProvider (role list) + rolePulseProvider (pulse state).
// Layout: responsive Wrap, min card width 280 px.
//
// Advisory-only (NAK-4): display-only page. No write paths.
// ---------------------------------------------------------------------------

/// Top-level page showing all roles as [RoleMemberCard] cards in a responsive
/// grid.
///
/// Empty state: "No roles found in agents/capabilities/".
/// Loading: circular progress indicator.
/// Error: inline error banner.
class TeamPage extends ConsumerWidget {
  // advisory-only (NAK-4)
  const TeamPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalogAsync = ref.watch(roleCatalogProvider);
    final pulseAsync = ref.watch(rolePulseProvider);

    // Resolve pulse map — default empty map when loading or on error.
    final pulseMap = pulseAsync.valueOrNull ?? const <String, RolePulse>{};

    return catalogAsync.when(
      data: (catalog) => _TeamGrid(catalog: catalog, pulseMap: pulseMap),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => _ErrorBanner(message: err.toString()),
    );
  }
}

// ---------------------------------------------------------------------------
// Grid layout
// ---------------------------------------------------------------------------

class _TeamGrid extends StatelessWidget {
  const _TeamGrid({
    required this.catalog,
    required this.pulseMap,
  });

  final List<RoleCapability> catalog;
  final Map<String, RolePulse> pulseMap;

  @override
  Widget build(BuildContext context) {
    if (catalog.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.group_outlined,
                size: 64,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 16),
              Text(
                'No roles found in agents/capabilities/',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withAlpha(140),
                    ),
              ),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final cap in catalog)
            SizedBox(
              // Min 280 px wide — at most ~4 per row at 1280 px.
              width: _cardWidth(context),
              child: RoleMemberCard(
                capability: cap,
                pulse: pulseMap[cap.role] ?? RolePulse.idle,
              ),
            ),
        ],
      ),
    );
  }

  /// Responsive card width — 280 px minimum, grows with viewport.
  double _cardWidth(BuildContext context) {
    final viewWidth = MediaQuery.of(context).size.width - 72 - 1 - 32;
    // 72 px rail + 1 px divider + 32 px padding
    if (viewWidth <= 320) return viewWidth;
    if (viewWidth <= 600) return (viewWidth - 12) / 2;
    if (viewWidth <= 900) return (viewWidth - 24) / 3;
    return (viewWidth - 36) / 4;
  }
}

// ---------------------------------------------------------------------------
// Error banner
// ---------------------------------------------------------------------------

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: colorScheme.error),
            const SizedBox(height: 12),
            Text(
              'Failed to load roles',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colorScheme.error,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurface.withAlpha(120),
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
