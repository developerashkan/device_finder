/// Scene state that the painters share — mutated by the ticker and by live
/// BLE data, NEVER by widget rebuilds.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// One beacon sweep result: which 1° sector was lit this frame.
class _SectorBucket {
  _SectorBucket(this.angleDeg)
      : litFrom = 0.0,
        litTo = 0.0;

  final double angleDeg;
  double litFrom;
  double litTo;
  double intensity = 0.0;
  double lastHit = -1e9;
}

class RadarScene extends ChangeNotifier {
  RadarScene({
    this.sectors = 360,
    this.periodSeconds = 2.2,
    this.decayPerSecond = 1.6,
  });

  /// Number of angular buckets (1° each).
  final int sectors;

  /// Seconds per full revolution.
  final double periodSeconds;

  /// Exponential brightness decay per second after a sector is lit.
  final double decayPerSecond;

  /// Beam angle in 1/100° integer units — integer phase tracking, no float
  /// drift.
  int phase = 0;
  double _phase = 0; // exact accumulator (1/100° units)

  /// Brightness 0..1 per sector.
  late final Float32List brightness = Float32List(sectors);

  final List<_SectorBucket> _buckets = List.generate(360, (i) => _SectorBucket(i.toDouble()));

  double _lastPhase = 0;

  /// Advance one frame; [dtSeconds] from the ticker (60fps ≈ 1/60).
  ///
  /// The phase accumulator keeps the fractional revolution so the beam moves
  /// smoothly and every sector gets lit on its turn (integer `round()` per
  /// frame skips a sector every ~4 frames — a visible 33% duty-cycle hole).
  void advance(double dtSeconds) {
    if (!dtSeconds.isFinite || dtSeconds <= 0) return;
    _phase = (_phase + 36000 / periodSeconds * dtSeconds) % 36000;
    phase = _phase.floor().clamp(0, 35999);

    final beam = phase / 100.0; // 0..360
    // Lit bucket = the one under the beam.
    final idx = beam.floor() % sectors;

    // Brighten the lit sector, decay everything.
    final decay = math.exp(-decayPerSecond * dtSeconds);
    final b = brightness;
    for (var i = 0; i < sectors; i++) {
      final v = b[i] * decay;
      b[i] = v < 0.004 ? 0.0 : v;
    }
    b[idx] = 1.0;
    _buckets[idx].intensity = 1.0;
    notifyListeners();
  }

  /// A sector was swept (lit) — the "lit sectors for swept areas" effect.
  void markSwept(int sectorIndex, double intensity) {
    if (sectorIndex < 0 || sectorIndex >= sectors) return;
    brightness[sectorIndex] = intensity.clamp(0.0, 1.0);
    _buckets[sectorIndex].intensity = intensity.clamp(0.0, 1.0);
    notifyListeners();
  }

  void setLastPhase(double lastPhase) => _lastPhase = lastPhase;
  double get lastPhase => _lastPhase;
}
