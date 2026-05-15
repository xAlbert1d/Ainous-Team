import 'package:flutter/material.dart';

import '../models/role_pulse.dart';

// ---------------------------------------------------------------------------
// PulseIndicator — three-state visual dot for role activity.
//
// States (all driven by Material 3 colorScheme — no hardcoded colors):
//   idle:         subtle dot, colorScheme.outline
//   activeNow:    pulsing dot with opacity breathing, colorScheme.primary
//   justFinished: solid dot, colorScheme.secondary
//
// Animation: AnimatedBuilder + Tween<double> for opacity breathing.
// No third-party packages.
//
// Advisory-only (NAK-4): display-only widget, no onTap.
// ---------------------------------------------------------------------------

/// Three-state activity dot for a role.
///
/// Renders a 10 px dot whose color and animation reflect [pulse]:
///   - [RolePulse.idle]         → muted outline dot
///   - [RolePulse.activeNow]    → pulsing primary-color dot
///   - [RolePulse.justFinished] → solid secondary-color dot
class PulseIndicator extends StatefulWidget {
  // advisory-only (NAK-4)
  const PulseIndicator({
    super.key,
    required this.pulse,
    this.size = 10.0,
  });

  final RolePulse pulse;

  /// Diameter of the dot in logical pixels. Defaults to 10.
  final double size;

  @override
  State<PulseIndicator> createState() => _PulseIndicatorState();
}

class _PulseIndicatorState extends State<PulseIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _opacityAnimation = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    _updateAnimation();
  }

  @override
  void didUpdateWidget(PulseIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pulse != widget.pulse) {
      _updateAnimation();
    }
  }

  void _updateAnimation() {
    if (widget.pulse == RolePulse.activeNow) {
      _controller.repeat(reverse: true);
    } else {
      _controller.stop();
      _controller.value = 1.0; // fully opaque for non-animated states
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = _dotColor(colorScheme);

    return Semantics(
      label: _semanticsLabel,
      child: AnimatedBuilder(
        animation: _opacityAnimation,
        builder: (context, _) {
          final opacity =
              widget.pulse == RolePulse.activeNow ? _opacityAnimation.value : 1.0;
          return Opacity(
            opacity: opacity,
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
          );
        },
      ),
    );
  }

  Color _dotColor(ColorScheme cs) {
    switch (widget.pulse) {
      case RolePulse.activeNow:
        return cs.primary;
      case RolePulse.justFinished:
        return cs.secondary;
      case RolePulse.idle:
        return cs.outline;
    }
  }

  String get _semanticsLabel {
    switch (widget.pulse) {
      case RolePulse.activeNow:
        return 'Active now';
      case RolePulse.justFinished:
        return 'Just finished';
      case RolePulse.idle:
        return 'Idle';
    }
  }
}
