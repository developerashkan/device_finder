/// Guided geometric calibration: RSSI samples at known distances are fit to
/// the linearized path-loss model in log10(d) space.
///
/// Rejects physically implausible fits (residual RMS > 8 dB, exponent outside
/// 1.5–4.5, TxPower outside −85…−35 dBm) — in that case defaults are kept and
/// the caller is advised to re-run.
library;

import 'dart:math' as math;

import '../model.dart';

class CalibrationResult {
  CalibrationResult({
    required this.profile,
    required this.accepted,
    required this.reason,
  });

  final CalibrationProfile profile;
  final bool accepted;
  final String? reason;
}

class Calibrator {
  Calibrator({this.minSamplesPerDistance = 50, this.maxResidualDb = 8.0});

  /// Samples needed per distance point before the fit is considered.
  final int minSamplesPerDistance;

  /// Fit rejected when residual RMS exceeds this (dB).
  final double maxResidualDb;

  /// Adds a sample at a known distance. Returns the running count at that
  /// distance.
  final Map<double, List<double>> _samples = {};

  void addSample(double knownDistanceMeters, double rssiDb) {
    (_samples[knownDistanceMeters] ??= []).add(rssiDb);
  }

  Map<double, int> get counts => _samples.map((k, v) => MapEntry(k, v.length));

  void reset() => _samples.clear();

  /// Runs the fit. Returns an accepted profile, or a rejected profile with a
  /// human-readable reason (defaults are kept by the caller).
  CalibrationResult fit({DateTime? at}) {
    if (_samples.length < 3) {
      return CalibrationResult(
        profile: CalibrationProfile.defaults,
        accepted: false,
        reason: 'Need ≥ 3 distances (have ${_samples.length}); collect at 1, 2, 4, 8 m.',
      );
    }
    final insufficient = _samples.entries.where((e) => e.value.length < minSamplesPerDistance).toList();
    if (insufficient.isNotEmpty) {
      return CalibrationResult(
        profile: CalibrationProfile.defaults,
        accepted: false,
        reason: 'Not enough samples at distance ${insufficient.first.key} m (${insufficient.first.value.length} < $minSamplesPerDistance).',
      );
    }

    // Medians per distance.
    final xs = <double>[];
    final ys = <double>[];
    final distances = <double>[];
    _samples.forEach((d, samples) {
      final sorted = [...samples]..sort();
      final median = sorted[sorted.length ~/ 2];
      distances.add(d);
      xs.add(math.log(d) / math.ln10); // log10(d)
      ys.add(median);
    });

    // Linear fit y = β0 + β1·x.
    final xbar = xs.fold(0.0, (a, b) => a + b) / xs.length;
    final ybar = ys.fold(0.0, (a, b) => a + b) / ys.length;
    var sxx = 0.0, sxy = 0.0;
    for (var i = 0; i < xs.length; i++) {
      sxx += (xs[i] - xbar) * (xs[i] - xbar);
      sxy += (xs[i] - xbar) * (ys[i] - ybar);
    }
    final beta1 = sxx.abs() < 1e-12 ? 0.0 : sxy / sxx;
    final beta0 = ybar - beta1 * xbar;

    final n = -beta1 / 10.0;
    final tx = beta0;

    // Residual RMS over the median points.
    var sum = 0.0;
    for (var i = 0; i < xs.length; i++) {
      final predicted = beta0 + beta1 * xs[i];
      sum += (ys[i] - predicted) * (ys[i] - predicted);
    }
    final residualRms = math.sqrt(sum / xs.length);

    String? reason;
    if (residualRms > maxResidualDb) {
      reason = 'Residual RMS ${residualRms.toStringAsFixed(1)} dB > $maxResidualDb dB — re-measure carefully.';
    } else if (n < 1.5 || n > 4.5) {
      reason = 'Exponent n=${n.toStringAsFixed(2)} outside plausible range [1.5, 4.5].';
    } else if (tx < -85 || tx > -35) {
      reason = 'TxPower ${tx.toStringAsFixed(0)} dBm outside plausible range [−85, −35].';
    }

    final profile = CalibrationProfile(
      txPower: tx,
      exponent: n,
      residualRmsDb: residualRms,
      calibratedAt: at ?? DateTime.now(),
      distancesUsed: distances,
      samplesPerDistance: minSamplesPerDistance,
    );
    return CalibrationResult(profile: profile, accepted: reason == null, reason: reason);
  }
}
