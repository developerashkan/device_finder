/// Geiger-counter haptics — accelerating feedback as the target nears.
///
/// A throttled timer (decoupled from the frame loop) emits a selection-style
/// tick at a rate that scales with proximity: farther = sparse ticks, closer
/// = rapid ticks that blur into a constant "hot" buzz under 0.5 m.
///
/// Safety rules: ticks only fire while distance updates keep arriving (a
/// stale or lost signal goes silent after [staleAfter]); [stop] silences
/// immediately and forgets the last distance.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class GeigerHaptics {
  GeigerHaptics({
    this.maxRangeMeters = 12.0,
    this.minIntervalMs = 90,
    this.staleAfter = const Duration(seconds: 3),
    void Function()? onTick,
    int Function()? clockMs,
  })  : _onTick = onTick ?? HapticFeedback.selectionClick,
        _clockMs = clockMs;

  /// Beyond this distance (m) no ticks fire.
  final double maxRangeMeters;

  /// Fastest allowed tick interval (ms) — below 0.5 m it saturates.
  final int minIntervalMs;

  /// Silence when no [update] arrived for this long.
  final Duration staleAfter;

  final void Function() _onTick;
  final int Function()? _clockMs;
  final Stopwatch _clock = Stopwatch()..start();
  int get _now => _clockMs?.call() ?? _clock.elapsedMilliseconds;

  Timer? _timer;
  Duration Function(double meters) _intervalFor = GeigerHaptics.intervalFor;
  double _lastDistance = double.infinity;
  int _lastUpdateMs = -1;
  int _lastTickMs = -1 << 30;

  /// Whether the tick loop is running.
  bool get isRunning => _timer != null;

  /// Starts (or restarts) the loop. [intervalFor] maps distance (m) to the
  /// pause between ticks; defaults to [GeigerHaptics.intervalFor].
  void start([Duration Function(double meters)? intervalFor]) {
    stop();
    _intervalFor = intervalFor ?? GeigerHaptics.intervalFor;
    _timer = Timer.periodic(const Duration(milliseconds: 40), (_) => poll());
  }

  /// One tick decision (called by the internal timer; public for tests).
  @visibleForTesting
  void poll() {
    if (_timer == null) return;
    final now = _now;
    final d = _lastDistance;
    if (!d.isFinite || d > maxRangeMeters) return;
    if (_lastUpdateMs < 0 || now - _lastUpdateMs > staleAfter.inMilliseconds) return;
    final interval = math.max(_intervalFor(d).inMilliseconds, minIntervalMs);
    if (now - _lastTickMs >= interval) {
      _lastTickMs = now;
      _onTick();
    }
  }

  /// Exponential rate: 2000 ms at 12 m → 90 ms at ≤ 0.3 m.
  static Duration intervalFor(double d) {
    final clamped = d.isFinite ? d.clamp(0.3, 12.0) : 12.0;
    final ms = 2000 * math.pow(clamped / 12.0, 2.0).toDouble();
    return Duration(milliseconds: ms.round().clamp(90, 2000));
  }

  /// Feeds the current distance (call whenever a fresh estimate arrives).
  /// Non-finite values are ignored.
  void update(double meters) {
    if (!meters.isFinite) return;
    _lastDistance = meters;
    _lastUpdateMs = _now;
  }

  /// Stops ticking immediately and forgets the last distance.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _lastDistance = double.infinity;
    _lastUpdateMs = -1;
  }

  void dispose() => stop();
}
