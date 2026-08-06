/// Movement-history scoring resolves the two-anchor geometric mirror
/// ambiguity — a fast, local "ML" model with no learned weights.
///
/// The score prefers the candidate that agrees with the recent trajectory:
///
///     S(c) = −[ a·J² + b·(1 − cos θ) ]
///
/// where J is the jump distance from the predicted position and θ is the
/// angle between the candidate direction and the recent heading. Hysteresis
/// prevents flip-flopping when candidates are nearly tied.
library;

import 'dart:math' as math;

class MirrorResolver {
  MirrorResolver({
    this.jumpWeight = 0.25, // a (m⁻²)
    this.headingWeight = 1.5, // b
    this.switchMargin = 1.0,
    this.relockMargin = 3.0,
    this.freshAnchorsMargin = 0.25,
    this.maxVelocity = 3.0,
    this.minFlipHeadingCos = 0.4,
  });

  final double jumpWeight;
  final double headingWeight;
  final double switchMargin;
  final double relockMargin;
  final double freshAnchorsMargin;
  final double maxVelocity;

  /// Minimum heading agreement (cos θ between candidate direction and recent
  /// heading) required for the alternate candidate to win a flip. A flip to
  /// the mirror side would appear as an abrupt heading reversal — gating on
  /// heading prevents false flips from noisy/degenerate geometry.
  final double minFlipHeadingCos;

  (double x, double y)? _lastFix;
  (double x, double y)? _prevFix;
  DateTime? _lastTime;
  final List<(double x, double y)> _history = [];

  int _locked = -1; // 0 = candidate a, 1 = candidate b
  int _consecutiveAltWins = 0;
  int _anchorSetGeneration = 0;
  int _lastAnchorSet = -1;

  void reset() {
    _lastFix = null;
    _prevFix = null;
    _lastTime = null;
    _history.clear();
    _locked = -1;
    _consecutiveAltWins = 0;
  }

  /// Resolves between two mirror candidates. The candidates may arrive in any
  /// physical order — the resolver normalizes them so candidate 0 is always
  /// the one with the larger y (upper side); ties break toward larger x. This
  /// keeps the "locked side" label stable across anchor flips.
  ///
  /// [anchorSetChanged] must be true when the anchor set changed since the
  /// previous call (threshold drops to re-lock quickly after reconfiguration).
  (double x, double y) resolve({
    required (double x, double y) a,
    required (double x, double y) b,
    required DateTime at,
    required bool anchorSetChanged,
  }) {
    if (anchorSetChanged) {
      _anchorSetGeneration++;
      _consecutiveAltWins = 0;
    }
    final fresh = _anchorSetGeneration != _lastAnchorSet;
    _lastAnchorSet = _anchorSetGeneration;
    final threshold = fresh ? freshAnchorsMargin : switchMargin;

    // Degenerate (single-point) geometry: no ambiguity to resolve — don't
    // commit, so the movement history is never polluted by projection fixes.
    final sep = math.sqrt((a.$1 - b.$1) * (a.$1 - b.$1) + (a.$2 - b.$2) * (a.$2 - b.$2));
    if (sep < 1e-6) {
      return _lastFix ?? a;
    }

    // Normalize: candidate 0 = upper (max y), candidate 1 = lower.
    final (double, double) c0;
    final (double, double) c1;
    if (a.$2 > b.$2 || (a.$2 == b.$2 && a.$1 >= b.$1)) {
      c0 = a;
      c1 = b;
    } else {
      c0 = b;
      c1 = a;
    }

    if (_lastFix == null) {
      // First fix: pick the candidate nearer to the predicted position
      // (weighted history centroid, or the first candidate).
      final predicted = _predictedPosition(at);
      final chosen = _score(c0, predicted, null) >= _score(c1, predicted, null) ? c0 : c1;
      _locked = chosen == c0 ? 0 : 1;
      _consecutiveAltWins = 0;
      _commit(chosen, at);
      return chosen;
    }

    final predicted = _predictedPosition(at);
    final heading = _heading();

    final sa = _score(c0, predicted, heading);
    final sb = _score(c1, predicted, heading);
    final winsA = sa >= sb;
    final preferred = winsA ? 0 : 1;
    final margin = (sa - sb).abs();

    // Every flip — even a large-margin one — must agree with the recent
    // heading, or it would imply an implausible reversal onto the mirror
    // side. (Without this gate, a walk behind a wall could force a flip via
    // the relock path.)
    if (preferred != _locked) {
      final alt = preferred == 0 ? c0 : c1;
      if (!_headingAgreement(alt, heading)) {
        _consecutiveAltWins = 0;
      } else if (margin > relockMargin) {
        _locked = preferred;
        _consecutiveAltWins = 0;
      } else {
        _consecutiveAltWins++;
        if (_consecutiveAltWins >= 2 && margin > threshold) {
          _locked = preferred;
          _consecutiveAltWins = 0;
        }
      }
    } else {
      _consecutiveAltWins = 0;
    }

    final chosen = _locked == 0 ? c0 : c1;
    _commit(chosen, at);
    return chosen;
  }

  /// Score candidate c given predicted position p̂ and heading unit vector h.
  double _score((double x, double y) c, (double x, double y)? predicted, (double x, double y)? heading) {
    var s = 0.0;
    if (predicted != null) {
      final j2 = (c.$1 - predicted.$1) * (c.$1 - predicted.$1) + (c.$2 - predicted.$2) * (c.$2 - predicted.$2);
      s -= jumpWeight * j2;
    }
    if (heading != null) {
      final dx = c.$1 - _lastFix!.$1;
      final dy = c.$2 - _lastFix!.$2;
      final norm = math.sqrt(dx * dx + dy * dy);
      if (norm > 1e-9) {
        final cosTheta = (dx * heading.$1 + dy * heading.$2) / norm;
        s -= headingWeight * (1.0 - cosTheta.clamp(-1.0, 1.0));
      }
    }
    return s;
  }

  /// Exponential-decay weighted centroid of recent fixes, extrapolated by
  /// velocity when available.
  (double x, double y)? _predictedPosition(DateTime at) {
    if (_lastFix == null) return null;
    if (_lastTime == null || _history.length < 2) {
      return _lastFix;
    }
    // Velocity from the last two fixes (capped).
    final dt = at.difference(_lastTime!).inSeconds.toDouble().clamp(0.05, 5.0);
    final vx = ((_lastFix!.$1 - _prevFix!.$1) / dt).clamp(-maxVelocity, maxVelocity);
    final vy = ((_lastFix!.$2 - _prevFix!.$2) / dt).clamp(-maxVelocity, maxVelocity);
    return (_lastFix!.$1 + vx * dt, _lastFix!.$2 + vy * dt);
  }

  (double x, double y)? _heading() {
    if (_lastFix == null || _prevFix == null) return null;
    final dx = _lastFix!.$1 - _prevFix!.$1;
    final dy = _lastFix!.$2 - _prevFix!.$2;
    final norm = math.sqrt(dx * dx + dy * dy);
    if (norm < 1e-6) return null;
    return (dx / norm, dy / norm);
  }

  /// True when the candidate direction from the last fix agrees with the
  /// recent heading beyond [minFlipHeadingCos] (or heading is unknown).
  bool _headingAgreement((double x, double y) c, (double x, double y)? heading) {
    if (heading == null || _lastFix == null) return true;
    final dx = c.$1 - _lastFix!.$1;
    final dy = c.$2 - _lastFix!.$2;
    final norm = math.sqrt(dx * dx + dy * dy);
    if (norm < 1e-9) return true;
    final cos = (dx * heading.$1 + dy * heading.$2) / norm;
    return cos >= minFlipHeadingCos;
  }

  void _commit((double x, double y) fix, DateTime at) {
    _prevFix = _lastFix;
    _lastFix = fix;
    _lastTime = at;
    _history.add(fix);
    if (_history.length > 16) _history.removeAt(0);
  }

  /// Side currently locked (0 or 1), for diagnostics.
  int get lockedSide => _locked;
}
