import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/role_pulse.dart';
import '../models/session_summary.dart';
import 'session_summary_provider.dart';

// ---------------------------------------------------------------------------
// rolePulseProvider — pure derivation over sessionSummariesProvider.
//
// Returns a Map<String, RolePulse> keyed by role name. Roles with no sessions
// are absent from the map; callers default to RolePulse.idle.
//
// Re-evaluates on:
//   1. Any sessionSummariesProvider update (new events → new pulse states).
//   2. A periodic 30-second wall-clock tick so "activeNow" → "justFinished"
//      → "idle" transitions happen even when no new events arrive.
//
// Advisory-only (NAK-4): pulse state drives display only; no state-changing
// action is taken from these values.
// ---------------------------------------------------------------------------

/// Derives a per-role [RolePulse] map from [sessionSummariesProvider].
///
/// Re-evaluates on provider updates and on a [kPulseTickInterval] timer so
/// time-driven transitions (active→finished→idle) happen without new events.
final rolePulseProvider =
    StreamProvider.autoDispose<Map<String, RolePulse>>((ref) async* {
  final controller = StreamController<Map<String, RolePulse>>();

  // Holds the most recently received session summaries.
  List<SessionSummary> latestSummaries = [];

  void recompute() {
    final now = DateTime.now();
    final result = _computePulse(latestSummaries, now);
    if (!controller.isClosed) controller.add(result);
  }

  // Re-compute whenever session summaries change.
  ref.listen<AsyncValue<List<SessionSummary>>>(
    sessionSummariesProvider,
    (_, next) {
      next.whenData((summaries) {
        latestSummaries = summaries;
        recompute();
      });
    },
    fireImmediately: true,
  );

  // Periodic tick so time-driven transitions fire without new events.
  final timer = Timer.periodic(kPulseTickInterval, (_) => recompute());

  ref.onDispose(() {
    timer.cancel();
    controller.close();
  });

  yield* controller.stream;
});

// ---------------------------------------------------------------------------
// Pure function — testable independently of the provider.
// ---------------------------------------------------------------------------

/// Computes a per-role [RolePulse] map given [summaries] and [now].
///
/// For each role seen across all summaries:
///   - [RolePulse.activeNow] if any session has [lastTimestamp] within
///     [kActiveNowThreshold] AND no terminal event (completed/failed).
///   - [RolePulse.justFinished] if the role's most-recent terminal-event
///     session has [lastTimestamp] within [kJustFinishedThreshold].
///   - [RolePulse.idle] otherwise.
///
/// If a role has both an active-now session and a just-finished session,
/// activeNow takes precedence.
Map<String, RolePulse> computePulse(
  List<SessionSummary> summaries,
  DateTime now,
) =>
    _computePulse(summaries, now);

Map<String, RolePulse> _computePulse(
  List<SessionSummary> summaries,
  DateTime now,
) {
  // Bucket summaries by role.
  final byRole = <String, List<SessionSummary>>{};
  for (final s in summaries) {
    final role = s.role;
    if (role == null || role.isEmpty) continue;
    byRole.putIfAbsent(role, () => []).add(s);
  }

  final result = <String, RolePulse>{};

  for (final entry in byRole.entries) {
    final role = entry.key;
    final sessions = entry.value;

    // Determine pulse for this role.
    RolePulse pulse = RolePulse.idle;

    for (final session in sessions) {
      final last = session.lastTimestamp;
      if (last == null) continue;

      final age = now.difference(last);
      final hasTerminal =
          session.eventTypes.any(kTerminalEvents.contains);

      if (!hasTerminal && age <= kActiveNowThreshold) {
        // Active in-flight session — highest priority, stop checking.
        pulse = RolePulse.activeNow;
        break;
      }

      if (hasTerminal && age <= kJustFinishedThreshold) {
        // Terminal session within just-finished window — upgrade if still idle.
        if (pulse == RolePulse.idle) {
          pulse = RolePulse.justFinished;
        }
      }
    }

    result[role] = pulse;
  }

  return result;
}
