/// Geiger-counter haptics — accelerating feedback as the target nears.
///
/// A throttled timer (decoupled from the frame loop) emits a selection-style
/// tick at a rate that scales with proximity: farther = sparse ticks, closer
/// = rapid ticks that blur into a constant "hot" buzz under 0.5 m.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';

class GeigerHaptics {
  GeigerHaptics({this.maxRangeMeters = 12.0, this.minIntervalMs = 90});

  /// Beyond this distance (m) no ticks fire.
  final double maxRangeMeters;

  /// Fastest allowed tick interval (ms) — below 0.5 m it saturates.
  final int minIntervalMs;

  Timer? _timer;
  double _lastDistance = double.infinity;
  double _lastTickMs = -1e9;

  /// Start the loop. [distanceProvider] returns the current distance in
  /// meters; called once per tick decision.
  void start(Duration Function(double distanceMs) intervalFor) {
    stop();
    _timer = Timer.periodic(const Duration(milliseconds: 40), (_) {
      final now = DateTime.now().millisecondsSinceEpoch.toDouble();
      if (now - _lastTickMs < 40) return;
      final d = _lastDistance;
      if (d.isInfinite || d > maxRangeMeters) return;
      final intervalMs = intervalFor(d).inMilliseconds.toDouble();
      if (now - _lastTickMs >= intervalMs) {
        _lastTickMs = now;
        HapticFeedback.selectionClick();
      }
    });
  }

  /// Simple exponential rate: ticks accelerate as distance drops.
  static Duration intervalFor(double d) {
    final clamped = d.clamp(0.3, 12.0);
    // 2000 ms at 12 m → 90 ms at 0.3 m (exponential).
    final ms = 2000 * math.pow(clamped / 12.0, 2.0).toDouble();
    return Duration(milliseconds: ms.round().clamp(90, 2000));
  }

  /// Update the current distance (call from the tracker loop).
  void update(double meters) => _lastDistance = meters;

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => stop();
}
