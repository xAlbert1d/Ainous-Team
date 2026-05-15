/// RolePulse — three-state enum describing the activity state of a role.
///
/// Pulse state is derived purely from [SessionSummary] data and wall-clock
/// time. It is advisory-only (NAK-4): no state-changing action is taken
/// from pulse values. The enum drives display only.
///
/// Thresholds:
///   [activeNow]    — role has an in-flight session whose lastTimestamp is
///                    within the last [kActiveNowThreshold] and no terminal
///                    event (completed/failed) has been seen.
///   [justFinished] — role has a session whose latest event was completed or
///                    failed within [kJustFinishedThreshold].
///   [idle]         — otherwise.
enum RolePulse {
  idle,
  activeNow,
  justFinished;
}

// ---------------------------------------------------------------------------
// Threshold constants — used by rolePulseProvider and unit tests.
// ---------------------------------------------------------------------------

/// Window within which a role is considered "active now" (no terminal event).
const kActiveNowThreshold = Duration(seconds: 60);

/// Window within which a role is considered "just finished" (terminal event).
const kJustFinishedThreshold = Duration(minutes: 5);

/// Terminal event types — a session with one of these is not "active now".
const kTerminalEvents = {'completed', 'failed'};

/// How often [rolePulseProvider] ticks the wall clock to re-evaluate states.
const kPulseTickInterval = Duration(seconds: 30);
