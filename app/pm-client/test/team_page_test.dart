// Team page sub-phase 1 tests.
//
// Coverage:
//   TC-TM1  computePulse returns activeNow for a role with a recent spawn
//           event and no completed event.
//   TC-TM2  computePulse returns justFinished for a role whose latest
//           event was completed within 5 minutes.
//   TC-TM3  computePulse returns idle for a role with no events OR whose
//           last event was over 5 minutes ago.
//   TC-TM4  RoleMemberCard renders name, avatar, description, and pulse.
//   TC-TM5  PulseIndicator renders three visually distinct states.
//   TC-TM6  TeamPage renders all roles from roleCatalogProvider as cards.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ainous_pm_client/models/role_capability.dart';
import 'package:ainous_pm_client/models/role_pulse.dart';
import 'package:ainous_pm_client/models/session_summary.dart';
import 'package:ainous_pm_client/providers/role_catalog_provider.dart';
import 'package:ainous_pm_client/providers/role_pulse_provider.dart';
import 'package:ainous_pm_client/widgets/pulse_indicator.dart';
import 'package:ainous_pm_client/widgets/role_member_card.dart';
import 'package:ainous_pm_client/widgets/team_page.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// Creates a [SessionSummary] with the given parameters.
SessionSummary _makeSession({
  required String sessionId,
  required String role,
  required DateTime lastTimestamp,
  List<String> eventTypes = const ['spawn'],
}) {
  return SessionSummary(
    sessionId: sessionId,
    role: role,
    firstTimestamp: lastTimestamp.subtract(const Duration(seconds: 5)),
    lastTimestamp: lastTimestamp,
    eventCount: eventTypes.length,
    eventTypes: eventTypes,
    isTainted: false,
    events: const [],
    skills: const [],
  );
}

const _devCapability = RoleCapability(
  role: 'developer',
  description: 'Implements features, fixes bugs, writes production code.',
  defaultSkills: ['tdd', 'debug', 'refactor'],
);

const _archCapability = RoleCapability(
  role: 'architect',
  description: 'Designs systems and reviews architecture.',
);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // TC-TM1 — activeNow
  // -------------------------------------------------------------------------

  test(
      'TC-TM1: computePulse returns activeNow for recent spawn with no terminal event',
      () {
    final now = DateTime.now();
    // Session last seen 20 seconds ago — within the 60-second activeNow window.
    final sessions = [
      _makeSession(
        sessionId: 'sess-1',
        role: 'developer',
        lastTimestamp: now.subtract(const Duration(seconds: 20)),
        eventTypes: ['spawn'], // no completed/failed
      ),
    ];

    final result = computePulse(sessions, now);

    expect(result['developer'], equals(RolePulse.activeNow));
  });

  // -------------------------------------------------------------------------
  // TC-TM2 — justFinished
  // -------------------------------------------------------------------------

  test(
      'TC-TM2: computePulse returns justFinished for completed event within 5 min',
      () {
    final now = DateTime.now();
    // Session completed 2 minutes ago — within the 5-minute justFinished window.
    final sessions = [
      _makeSession(
        sessionId: 'sess-2',
        role: 'architect',
        lastTimestamp: now.subtract(const Duration(minutes: 2)),
        eventTypes: ['spawn', 'completed'],
      ),
    ];

    final result = computePulse(sessions, now);

    expect(result['architect'], equals(RolePulse.justFinished));
  });

  // -------------------------------------------------------------------------
  // TC-TM3 — idle (three sub-cases)
  // -------------------------------------------------------------------------

  test('TC-TM3: computePulse returns idle (empty map) for no sessions', () {
    final result = computePulse([], DateTime.now());
    // No role entries at all — callers default to RolePulse.idle.
    expect(result, isEmpty);
  });

  test(
      'TC-TM3b: computePulse returns idle for role whose completed event was over 5 min ago',
      () {
    final now = DateTime.now();
    final sessions = [
      _makeSession(
        sessionId: 'sess-3',
        role: 'tester',
        lastTimestamp: now.subtract(const Duration(minutes: 10)),
        eventTypes: ['spawn', 'completed'],
      ),
    ];

    final result = computePulse(sessions, now);

    expect(result['tester'], equals(RolePulse.idle));
  });

  test(
      'TC-TM3c: computePulse returns idle for spawn-only session older than 60 s',
      () {
    final now = DateTime.now();
    final sessions = [
      _makeSession(
        sessionId: 'sess-4',
        role: 'writer',
        lastTimestamp: now.subtract(const Duration(seconds: 90)),
        eventTypes: ['spawn'], // no terminal event, but outside activeNow window
      ),
    ];

    final result = computePulse(sessions, now);

    expect(result['writer'], equals(RolePulse.idle));
  });

  // -------------------------------------------------------------------------
  // TC-TM4 — RoleMemberCard renders expected content
  // -------------------------------------------------------------------------

  testWidgets(
      'TC-TM4: RoleMemberCard renders name, description, and pulse indicator',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF5B4CF5),
          ),
          useMaterial3: true,
        ),
        home: const Scaffold(
          body: SizedBox(
            width: 300,
            child: RoleMemberCard(
              capability: _devCapability,
              pulse: RolePulse.activeNow,
            ),
          ),
        ),
      ),
    );

    // Role name appears.
    expect(find.text('developer'), findsOneWidget);

    // Description appears.
    expect(find.textContaining('Implements features'), findsOneWidget);

    // PulseIndicator is rendered (widget type present).
    expect(find.byType(PulseIndicator), findsOneWidget);

    // RoleAvatar initial 'D' appears.
    expect(find.text('D'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // TC-TM5 — PulseIndicator renders three visually distinct states
  // -------------------------------------------------------------------------

  testWidgets(
      'TC-TM5: PulseIndicator idle renders a dot widget (no active animation)',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: const Scaffold(
          body: Center(child: PulseIndicator(pulse: RolePulse.idle)),
        ),
      ),
    );

    expect(find.byType(PulseIndicator), findsOneWidget);
    // Opacity is 1.0 (no active animation for idle state).
    final opacity = tester.widget<Opacity>(find.byType(Opacity));
    expect(opacity.opacity, equals(1.0));
  });

  testWidgets(
      'TC-TM5b: PulseIndicator activeNow renders with AnimatedBuilder for pulsing',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: const Scaffold(
          body: Center(child: PulseIndicator(pulse: RolePulse.activeNow)),
        ),
      ),
    );

    // The widget itself is present.
    expect(find.byType(PulseIndicator), findsOneWidget);
    // AnimatedBuilder is used internally for the breathing animation.
    // Use findsWidgets (>=1) since Material/InkWell may also use AnimatedBuilder.
    expect(find.byType(AnimatedBuilder), findsWidgets);
    // Opacity widget is used for animation.
    expect(find.byType(Opacity), findsOneWidget);
  });

  testWidgets(
      'TC-TM5c: PulseIndicator justFinished renders a solid dot (full opacity)',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: const Scaffold(
          body: Center(child: PulseIndicator(pulse: RolePulse.justFinished)),
        ),
      ),
    );

    expect(find.byType(PulseIndicator), findsOneWidget);
    // Opacity is 1.0 for non-animated states.
    final opacity = tester.widget<Opacity>(find.byType(Opacity));
    expect(opacity.opacity, equals(1.0));
  });

  // -------------------------------------------------------------------------
  // TC-TM6 — TeamPage renders all roles from roleCatalogProvider as cards
  // -------------------------------------------------------------------------

  testWidgets(
      'TC-TM6: TeamPage renders all roles from roleCatalogProvider as cards',
      (tester) async {
    const catalog = [_devCapability, _archCapability];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          roleCatalogProvider.overrideWith(
            (ref) => Stream.value(catalog),
          ),
          rolePulseProvider.overrideWith(
            (ref) => Stream.value(const <String, RolePulse>{}),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF5B4CF5),
            ),
            useMaterial3: true,
          ),
          home: const Scaffold(body: TeamPage()),
        ),
      ),
    );

    // Let StreamProviders emit their values.
    await tester.pump();
    await tester.pump();

    // Both role names should appear as card titles.
    expect(find.text('developer'), findsOneWidget);
    expect(find.text('architect'), findsOneWidget);

    // Exactly two RoleMemberCards rendered.
    expect(find.byType(RoleMemberCard), findsNWidgets(2));
  });
}
