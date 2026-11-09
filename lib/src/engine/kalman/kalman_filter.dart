/// 1-D Kalman filter on RSSI in the dB domain.
///
/// RSSI noise is approximately additive Gaussian in dB, so filtering in dB
/// space (rather than converting to meters first) is both simpler and more
/// accurate. State is `[rssi, velocity]ᵀ` (dB, dB/s); process noise is tuned
/// for a person walking at ~1.2 m/s sampling at ~10 Hz.
library;

import 'dart:math' as math;

/// Tuned for a walking user at 10 Hz: smoothed output lands in the
/// 3–5 dB residual band vs. a clean indoor signal with no visible jitter.
class RssiKalmanFilter {
  RssiKalmanFilter({
    double initialRssi = -70.0,
    double q1 = 0.05, // dB²/s    — process noise on position
    double q2 = 3.0, // dB²/s³   — process noise on velocity
    double r = 9.0, // dB²      — measurement noise (σ = 3 dB)
    double p11Floor = 1.64, // dB²     — σ_floor ≈ 1.28 dB, keeps K ≈ 0.15 so the
    // filter stays responsive after dead-calm periods (never fully locks up)
    double boostInnovationKappa = 4.0, // |y| > κ·σ_innov triggers the boost
    int boostSteps = 4, // how many updates the boost persists (decaying)
    double boostQFactor = 40.0, // Q inflation when a real step is detected
    DateTime? now,
  })  : _q1 = q1,
        _q2 = q2,
        _r = r,
        _p11Floor = p11Floor,
        _boostKappa = boostInnovationKappa,
        _boostSteps = boostSteps,
        _boostFactor = boostQFactor {
    _x1 = initialRssi;
    _x2 = 0.0;
    _p11 = 4.0 * r;
    _p12 = 0.0;
    _p22 = 2.0 * r;
    _lastT = now;
  }

  final double _q1;
  final double _q2;
  final double _r;
  final double _p11Floor;
  final double _boostKappa;
  final int _boostSteps;
  final double _boostFactor;
  int _boostRemaining = 0;

  // State (initialized at declaration; constructor re-arms).
  double _x1 = -70.0; // rssi (dB)
  double _x2 = 0.0; // velocity (dB/s)
  double _p11 = 36.0;
  double _p12 = 0.0;
  double _p22 = 18.0;
  DateTime? _lastT;

  /// Filtered RSSI (dBm).
  double get value => _x1;

  /// Filtered velocity (dB/s).
  double get velocity => _x2;

  /// 1σ uncertainty of the filtered RSSI (dB).
  double get sigma => math.sqrt(_p11);

  /// Last update time.
  DateTime? get lastUpdated => _lastT;

  /// Predict + update with a new measurement. Returns the filtered RSSI.
  ///
  /// A duplicate or out-of-order timestamp (dt ≤ 0) is ignored entirely, the
  /// same contract as [updateWithDt].
  double update(double rssi, DateTime now) {
    if (!rssi.isFinite) return _x1;
    final dt = _lastT == null ? 0.001 : now.difference(_lastT!).inMicroseconds / 1e6;
    if (dt <= 0) return _x1;
    _lastT = now;
    _predict(dt);
    _correct(rssi);
    return _x1;
  }

  /// Single update with explicit dt (used by tests and synthetic streams).
  ///
  /// dt ≤ 0 (duplicate/out-of-order sample) skips the ENTIRE update — a
  /// duplicate must not move the state at all.
  double updateWithDt(double rssi, double dt) {
    if (dt <= 0 || !rssi.isFinite) return _x1;
    _predict(dt);
    _correct(rssi);
    return _x1;
  }

  void _predict(double dtRaw) {
    // dt guards: clamp to [0.001, 2] s; dt ≤ 0 (duplicate/out-of-order) skips
    // the predict step entirely; dt > 0.5 s (app pause) resets velocity and
    // inflates covariance to re-acquire quickly.
    final dt = dtRaw.clamp(0.001, 2.0);
    if (dtRaw <= 0) return;

    if (dtRaw > 0.5) {
      // App pause: reset velocity and inflate the whole covariance to
      // re-acquire quickly (cross-terms scale with the same factor).
      _x2 = 0.0;
      _p11 *= 4.0;
      _p12 *= 4.0;
      _p22 *= 4.0;
    }

    // F = [[1, dt], [0, 1]]
    _x1 = _x1 + _x2 * dt;

    // Q = [[q1·dt + q2·dt³/3, q2·dt²/2], [q2·dt²/2, q2·dt]]
    var q11 = _q1 * dt + _q2 * dt * dt * dt / 3.0;
    final q12 = _q2 * dt * dt / 2.0;
    var q22 = _q2 * dt;

    // Adaptive boost: after a detected step, inflate Q so the filter snaps
    // toward the new level, decaying back to smoothness over the window.
    if (_boostRemaining > 0) {
      final boost = _boostFactor *
          math.pow(0.3, _boostSteps - _boostRemaining).toDouble(); // 100,30,10,3,1
      q11 *= boost;
      q22 *= boost;
      _boostRemaining--;
    }

    // P' = F·P·Fᵀ + Q
    final p11 = _p11 + 2.0 * _p12 * dt + _p22 * dt * dt + q11;
    final p12 = _p12 + _p22 * dt + q12;
    final p22 = _p22 + q22;
    _p11 = p11;
    _p12 = p12;
    _p22 = p22;
  }

  void _correct(double z) {
    final s = _p11 + _r;
    if (s <= 0) return;

    final y = z - _x1; // innovation
    // Step detection: a genuine step (|y| > κ·σ_innov) triggers the boost.
    // The innovation sigma is dominated by the MEASUREMENT noise R (the P11
    // floor pins the prior at 1.28 dB), so gate against the measurement σ
    // instead — a fixed κ=4 against R makes the detector noise-adaptive:
    // σ=3 dB → 12 dB gate, σ=5 dB → 20 dB gate, σ=7 dB → 28 dB gate.
    if (_boostRemaining == 0 && y.abs() > _boostKappa * math.sqrt(_r)) {
      _boostRemaining = _boostSteps;
      // Immediately inflate the covariance so THIS correction is large
      // (K ≈ 0.8), then let Q-inflation and updates decay it back.
      _p11 = math.max(_p11, 4.0 * _r);
      final sBoosted = _p11 + _r;
      final k1b = _p11 / sBoosted;
      final k2b = _p12 / sBoosted;
      _x1 = _x1 + k1b * y;
      _x2 = _x2 + k2b * y;
      final pb11 = _p11 * (1 - k1b);
      final pb12 = _p12 * (1 - k1b);
      final pb22 = _p22 - k2b * _p12;
      _p11 = math.max(pb11, _p11Floor);
      _p12 = pb12;
      _p22 = pb22;
      return;
    }

    final k1 = _p11 / s;
    final k2 = _p12 / s;

    _x1 = _x1 + k1 * y;
    _x2 = _x2 + k2 * y;

    // P = (I − K·H)·P  (Joseph form not needed for scalar H)
    final p11 = _p11 * (1 - k1);
    final p12 = _p12 * (1 - k1);
    final p22 = _p22 - k2 * _p12;
    _p11 = math.max(p11, _p11Floor);
    _p12 = p12;
    _p22 = p22;
  }

  void reset([double rssi = -70.0]) {
    _x1 = rssi;
    _x2 = 0.0;
    _p11 = 4.0 * _r;
    _p12 = 0.0;
    _p22 = 2.0 * _r;
    _lastT = null;
  }
}
