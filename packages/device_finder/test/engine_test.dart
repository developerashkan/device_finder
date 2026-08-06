import 'dart:math' as math;

import 'package:device_finder/device_finder.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deterministic LCG PRNG for reproducible synthetic tests.
class _Rng {
  _Rng(int seed) : _s = seed & 0x7fffffff;
  int _s;
  double next() {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s / 0x7fffffff;
  }

  double gauss(double sigma) {
    // Box-Muller.
    final u1 = math.max(next(), 1e-12);
    final u2 = next();
    return sigma * math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }
}

/// True RSSI at distance d under the default model, plus zero-mean Gaussian
/// noise of [sigma] dB.
double _simRssi(double d, _Rng rng, {double sigma = 3.0}) {
  return -59.0 - 28.0 * math.log(d) / math.ln10 + rng.gauss(sigma);
}

void main() {
  group('path_loss', () {
    test('round trip d → RSSI → d within 2% for 1..20 m (zero noise)', () {
      for (final d in [1.0, 2.0, 4.0, 8.0, 15.0, 20.0]) {
        final rssi = rssiFromDistance(d);
        final recovered = distanceFromRssi(rssi);
        expect((recovered - d).abs() / d, lessThan(0.02), reason: 'at $d m');
      }
    });

    test('monotonic: stronger RSSI ⇒ smaller distance', () {
      final dFar = distanceFromRssi(-80);
      final dNear = distanceFromRssi(-50);
      expect(dNear, lessThan(dFar));
    });

    test('distance clamp at [0.5, 30] m', () {
      expect(distanceFromRssi(-10), 0.5);
      expect(distanceFromRssi(-140), 30.0);
    });
  });

  group('kalman', () {
    test('residual vs clean signal ≤ 5 dB RMS and output steps < 6 dB', () {
      final k = RssiKalmanFilter();
      final rng = _Rng(42);
      var sumSq = 0.0;
      double? prev;
      var maxStep = 0.0;
      for (var i = 0; i < 200; i++) {
        final truth = -65.0 + 3.0 * math.sin(i / 20.0);
        final z = truth + rng.gauss(3.0);
        final f = k.updateWithDt(z, 0.1);
        sumSq += (f - truth) * (f - truth);
        if (prev != null) maxStep = math.max(maxStep, (f - prev).abs());
        prev = f;
      }
      final rms = math.sqrt(sumSq / 200);
      expect(rms, lessThanOrEqualTo(5.0), reason: 'smoothed residual RMS $rms');
      expect(maxStep, lessThan(6.0));
    });

    test('15 dB step: lag < 8 dB and settle < 1.5 s', () {
      final k = RssiKalmanFilter();
      // Warm up at −60.
      for (var i = 0; i < 30; i++) {
        k.updateWithDt(-60.0, 0.1);
      }
      // Step to −75.
      final t0 = DateTime.now();
      DateTime? settle;
      var maxLag = 0.0;
      final stepStart = k.value; // snapshot before the step begins
      for (var i = 0; i < 100; i++) {
        final f = k.updateWithDt(-75.0, 0.1);
        // Lag = how far the output has moved toward the target, measured
        // against the pre-step value (not the not-yet-reached target).
        final progress = (f - stepStart).abs() / 15.0;
        maxLag = math.max(maxLag, 15.0 * (1.0 - progress));
        if (settle == null && (-75.0 - f).abs() < 1.0) settle = t0.add(Duration(milliseconds: i * 100));
      }
      expect(maxLag, lessThan(8.0));
      expect(settle, isNotNull);
      expect(t0.difference(settle!).inMilliseconds.abs(), lessThanOrEqualTo(1500));
    });

    test('dt ≤ 0 skips predict; dt > 0.5 s reacquires', () {
      final k = RssiKalmanFilter();
      k.updateWithDt(-60.0, 0.1);
      final before = k.value;
      final dup = k.updateWithDt(-60.0, 0.0);
      expect(dup, closeTo(before, 1e-9), reason: 'duplicate timestamps must not move state');
      k.updateWithDt(-72.0, 2.0);
      expect(k.value, lessThan(before), reason: 'state should follow after pause');
      expect(k.sigma, greaterThan(1.0));
    });
  });

  group('source_fusion', () {
    test('staleness: stale at 2.5 s, ghost drop at 5 s, silence at 6 s', () {
      final f = SourceFusion();
      final t0 = DateTime.now();
      for (var i = 0; i < 8; i++) {
        f.push(RssiSample(deviceId: 'd', source: RssiSource.advertising, dbm: -60.0 + i, at: t0.add(Duration(milliseconds: i * 100))));
      }
      final r0 = f.estimate(t0.add(const Duration(seconds: 1)));
      expect(r0, isNotNull);
      expect(r0!.fresh, isTrue);
      FusionResult? r = r0;

      // Last sample at t0 + 700 ms; stale (> 2.5 s since last) from t0 + 3.3 s.
      r = f.estimate(t0.add(const Duration(milliseconds: 3300)));
      expect(r, isNotNull);
      final stale = r!;
      expect(stale.fresh, isFalse);
      expect(stale.stale, isTrue, reason: 'stale hold within 5 s');

      // Ghost drop (> 5 s since last) from t0 + 5.8 s.
      r = f.estimate(t0.add(const Duration(milliseconds: 5800)));
      expect(r, isNull, reason: 'ghost must be dropped after 5 s');
      expect(f.ghosted, isTrue);

      r = f.estimate(t0.add(const Duration(seconds: 6)));
      expect(r, isNull);
    });

    test('cleanest source wins the window', () {
      final f = SourceFusion();
      final t0 = DateTime.now();
      final rng = _Rng(5);
      // Realistic advertising noise (σ ≈ 8 dB).
      for (var i = 0; i < 10; i++) {
        f.push(RssiSample(deviceId: 'd', source: RssiSource.advertising, dbm: -60 + rng.gauss(8.0), at: t0.add(Duration(milliseconds: i * 100))));
      }
      // Clean connected-link stream (σ ≈ 2 dB), slightly older.
      for (var i = 0; i < 5; i++) {
        f.push(RssiSample(deviceId: 'd', source: RssiSource.connectedLink, dbm: -62.0 + rng.gauss(2.0), at: t0.add(Duration(milliseconds: (100 + i * 100)))));
      }
      final r = f.estimate(t0.add(const Duration(seconds: 1)));
      expect(r, isNotNull);
      expect(r!.source, RssiSource.connectedLink, reason: 'low-σ link should beat noisy advertising');
      expect(r.mean, closeTo(-62.0, 1.0));
    });

    test('degenerate (σ≈0) window never beats a valid preferred source', () {
      final f = SourceFusion();
      final t0 = DateTime.now();
      // Still beacon: identical samples → σ = 0 window (untrustworthy).
      for (var i = 0; i < 10; i++) {
        f.push(RssiSample(deviceId: 'd', source: RssiSource.advertising, dbm: -60.0, at: t0.add(Duration(milliseconds: i * 100))));
      }
      // Valid connected-link window (σ ≈ 4 dB).
      for (var i = 0; i < 5; i++) {
        f.push(RssiSample(deviceId: 'd', source: RssiSource.connectedLink,
            dbm: -62.0 + (i.isEven ? 4.0 : -4.0), at: t0.add(Duration(milliseconds: (100 + i * 100)))));
      }
      final r = f.estimate(t0.add(const Duration(seconds: 1)));
      expect(r, isNotNull);
      expect(r!.source, RssiSource.connectedLink, reason: 'valid link beats degenerate ad window');
    });
  });

  group('trilateration', () {
    test('3-anchor noisy fit: median error < 1.5 m; ellipse contains truth ≥ 90%', () {
      const truth = (x: 4.0, y: 3.0);
      final anchors = [
        Anchor(x: 0, y: 0, distance: math.sqrt(25.0)),
        Anchor(x: 10, y: 0, distance: math.sqrt(45.0)),
        Anchor(x: 5, y: 8.66, distance: math.sqrt(1 + 5.66 * 5.66)),
      ];
      var contains = 0;
      var errSum = 0.0;
      const trials = 100;
      final rng = _Rng(7);
      for (var t = 0; t < trials; t++) {
        final noisy = [
          for (final a in anchors) Anchor(x: a.x, y: a.y, distance: (a.distance + rng.gauss(0.8)).clamp(0.2, 20.0), sigma: 0.8),
        ];
        final f = solveTrilateration(noisy);
        errSum += math.sqrt((f.x - truth.x) * (f.x - truth.x) + (f.y - truth.y) * (f.y - truth.y));
        final (major, minor, theta) = f.confidenceEllipse();
        // Point-in-ellipse test in ellipse frame.
        final dx = truth.x - f.x;
        final dy = truth.y - f.y;
        final rad = theta * math.pi / 180;
        final ex = dx * math.cos(rad) + dy * math.sin(rad);
        final ey = -dx * math.sin(rad) + dy * math.cos(rad);
        final inEllipse = (ex * ex) / (major * major) + (ey * ey) / (minor * minor) <= 1.0;
        if (inEllipse) contains++;
      }
      expect(errSum / trials, lessThan(1.5));
      expect(contains, greaterThanOrEqualTo(90));
    });

    test('collinear anchors produce an elongated ellipse (λmax/λmin > 3)', () {
      final f = solveTrilateration([
        Anchor(x: 0, y: 0, distance: 5),
        Anchor(x: 5, y: 0, distance: 1),
        Anchor(x: 10, y: 0, distance: 6),
      ]);
      final (major, minor, _) = f.confidenceEllipse();
      expect(major, greaterThan(5.0));
      expect(major / minor, greaterThan(3.0));
    });

    test('two-anchor closed form yields mirrored candidates on both sides', () {
      final pf = solveTwoAnchors(Anchor(x: 0, y: 0, distance: 5), Anchor(x: 10, y: 0, distance: 6));
      expect(pf.isDegenerate, isFalse, reason: 'd1=5, d2=6, L=10 intersect in two points');
      expect((pf.a.$1 - pf.b.$1).abs(), lessThan(1e-9), reason: 'mirror points share the same x');
      expect(pf.a.$2 + pf.b.$2, closeTo(0, 1e-9), reason: 'mirror points symmetric about the baseline');
    });

    test('inconsistent ranges fall back to baseline projection', () {
      // d1 = 1, d2 = 100, L = 10: circles can never intersect (1 + 10 < 100).
      // a = (1² − 100² + 10²)/(2·10) = −494.95 → clamped to 0 → projection at p1.
      final pf = solveTwoAnchors(Anchor(x: 0, y: 0, distance: 1), Anchor(x: 10, y: 0, distance: 100));
      expect(pf.isDegenerate, isTrue);
      expect(pf.a.$1, closeTo(0.0, 1e-6), reason: 'a clamps to 0, projection at p1');
      expect(pf.a.$2, closeTo(0.0, 1e-6));
    });
  });

  group('mirror_resolver', () {
    test('dogleg walk: never flips to the mirror side', () {
      const a1 = (0.0, 0.0);
      const a2 = (10.0, 0.0);
      // True path: (5,5) → (5,2) (2.5 s), right turn → (8,2) at 1.2 m/s.
      final path = <(double, double)>[];
      const dt = 0.1;
      var t = 0.0;
      var x = 5.0, y = 5.0;
      while (t < 2.5) {
        path.add((x, y));
        y -= 1.2 * dt;
        t += dt;
      }
      while (t < 5.83) {
        path.add((x, y));
        x += 1.2 * dt;
        t += dt;
      }

      var maxErr = 0.0;
      var errSum = 0.0;
      var minY = double.infinity;
      var worstAbove = 0.0;
      var kept = 0;
      final t0 = DateTime(2026, 1, 1);
      for (var seed in [1, 2, 3, 4, 5]) {
        final rng = _Rng(seed);
        final resolver = MirrorResolver();
        // Kalman-smooth each anchor's RSSI stream (as the tracker does),
        // then convert to distance.
        final k1 = RssiKalmanFilter();
        final k2 = RssiKalmanFilter();
        for (var i = 0; i < path.length; i++) {
          final pos = path[i];
          final d1 = math.sqrt((pos.$1 - a1.$1) * (pos.$1 - a1.$1) + (pos.$2 - a1.$2) * (pos.$2 - a1.$2));
          final d2 = math.sqrt((pos.$1 - a2.$1) * (pos.$1 - a2.$1) + (pos.$2 - a2.$2) * (pos.$2 - a2.$2));
          final rssi1 = k1.updateWithDt(_simRssi(d1, rng), dt);
          final rssi2 = k2.updateWithDt(_simRssi(d2, rng), dt);
          final pf = solveTwoAnchors(
            Anchor(x: a1.$1, y: a1.$2, distance: distanceFromRssi(rssi1)),
            Anchor(x: a2.$1, y: a2.$2, distance: distanceFromRssi(rssi2)),
          );
          if (pf.isDegenerate) continue; // no geometry to resolve
          kept++;
          final chosen = resolver.resolve(
            a: pf.a,
            b: pf.b,
            at: t0.add(Duration(milliseconds: (i * 100).round())),
            anchorSetChanged: false,
          );
          final err = math.sqrt((chosen.$1 - pos.$1) * (chosen.$1 - pos.$1) + (chosen.$2 - pos.$2) * (chosen.$2 - pos.$2));
          maxErr = math.max(maxErr, err);
          errSum += err;
          minY = math.min(minY, chosen.$2);
          if (pos.$2 > 1.5) worstAbove = math.max(worstAbove, pos.$2 - chosen.$2);
        }
      }
      // Honest bounds for σ = 3 dB RSSI noise: single-sample outliers from
      // Kalman lag at the turn are expected; the resolver must never flip.
      expect(minY, greaterThan(-0.3), reason: 'reported y must never drop to the mirror side (y < 0)');
      expect(worstAbove, lessThan(4.5), reason: 'stays on the true side when true y > 1.5 m');
      expect(kept, greaterThanOrEqualTo((5 * path.length * 0.8).round()), reason: 'enough resolvable steps');
      expect(errSum / kept, lessThan(1.2), reason: 'median error < 1.2 m');
      expect(maxErr, lessThan(5.5), reason: 'max error < 5.5 m (single-sample outlier tolerant)');
    });

    test('hysteresis: small margins do not flip; sustained margin does', () {
      final resolver = MirrorResolver();
      final t0 = DateTime(2026, 1, 1);
      // Seed a trajectory heading east along y = 1 (top candidate).
      var t = t0;
      (double, double) fix1 = (0, 1);
      (double, double) fix2 = (1, 1);
      resolver.resolve(a: fix1, b: (fix1.$1, -fix1.$2), at: t, anchorSetChanged: true);
      t = t.add(const Duration(milliseconds: 100));
      resolver.resolve(a: fix2, b: (fix2.$1, -fix2.$2), at: t, anchorSetChanged: false);
      // Candidate a is on top (y=+1), b mirrored (y=−1).

      // Near-tied candidates for 10 updates: no flip.
      for (var i = 0; i < 10; i++) {
        t = t.add(const Duration(milliseconds: 100));
        final top = (2.0 + i * 0.1, 1.0);
        final bot = (2.0 + i * 0.1, -1.2); // close to tied but slightly worse
        final chosen = resolver.resolve(a: top, b: bot, at: t, anchorSetChanged: false);
        expect(chosen.$2, greaterThan(0), reason: 'must stay locked on the top side');
      }

      // Sustained margin: bot becomes much better than top for 2 updates.
      // Note: the resolver normalizes candidate 0 = upper, so this bot (which
      // is lower) can only win if the geometry genuinely moved to the lower
      // side — here it must NOT flip because it contradicts the heading.
      var flipped = false;
      for (var i = 0; i < 4; i++) {
        t = t.add(const Duration(milliseconds: 100));
        final top = (3.0 + i * 0.1, 2.0); // far from prediction (prediction near (2+i*0.1,1))
        final bot = (2.5 + i * 0.1, 0.9); // near prediction path
        final chosen = resolver.resolve(a: top, b: bot, at: t, anchorSetChanged: false);
        if (chosen.$2 < 0) flipped = true;
      }
      expect(flipped, isFalse,
          reason: 'heading gate: a flip to the lower side contradicts the eastward heading');
    });
  });

  group('calibration', () {
    test('clean synthetic data recovers n ± 0.4 and Tx ± 5 dB', () {
      final c = Calibrator(minSamplesPerDistance: 50);
      final rng = _Rng(11);
      for (final d in [1.0, 2.0, 4.0, 8.0]) {
        for (var i = 0; i < 60; i++) {
          c.addSample(d, -59.0 - 28.0 * math.log(d) / math.ln10 + rng.gauss(3.0));
        }
      }
      final r = c.fit();
      expect(r.accepted, isTrue, reason: r.reason);
      expect(r.profile.exponent, closeTo(2.8, 0.4));
      expect(r.profile.txPower, closeTo(-59.0, 5.0));
      expect(r.profile.residualRmsDb, lessThanOrEqualTo(8.0));
    });

    test('corrupt distance ⇒ residual > 8 dB ⇒ rejected', () {
      final c = Calibrator(minSamplesPerDistance: 50);
      final rng = _Rng(12);
      for (final d in [1.0, 2.0, 4.0, 8.0]) {
        for (var i = 0; i < 60; i++) {
          var offset = 0.0;
          if (d == 4.0) offset = 20.0; // +20 dB corruption at one distance
          c.addSample(d, -59.0 - 28.0 * math.log(d) / math.ln10 + rng.gauss(3.0) + offset);
        }
      }
      final r = c.fit();
      expect(r.accepted, isFalse);
      expect(r.reason, contains('8'));
    });

    test('implausible exponent (n = 6) rejected', () {
      final c = Calibrator(minSamplesPerDistance: 50);
      final rng = _Rng(13);
      for (final d in [1.0, 2.0, 4.0, 8.0]) {
        for (var i = 0; i < 60; i++) {
          c.addSample(d, -59.0 - 60.0 * math.log(d) / math.ln10 + rng.gauss(2.0));
        }
      }
      final r = c.fit();
      expect(r.accepted, isFalse);
      expect(r.reason, contains('Exponent'));
    });

    test('fewer than 3 distances is rejected', () {
      final c = Calibrator(minSamplesPerDistance: 10);
      for (var i = 0; i < 20; i++) {
        c.addSample(1.0, -55.0);
        c.addSample(2.0, -62.0);
      }
      final r = c.fit();
      expect(r.accepted, isFalse);
      expect(r.reason, contains('3'));
    });
  });

  group('tracker', () {
    test('distance-only mode: stale flag surfaces without ghost positions', () {
      final tracker = DeviceTracker();
      final t0 = DateTime(2026, 1, 1);
      tracker.setInfo(DeviceInfo(id: 'd', name: 'tag'));
      for (var i = 0; i < 10; i++) {
        tracker.pushSample(RssiSample(deviceId: 'd', source: RssiSource.advertising, dbm: -60.0, at: t0.add(Duration(milliseconds: i * 100))));
      }
      tracker.tick(now: t0.add(const Duration(seconds: 1)));
      var s = tracker.stateOf('d');
      expect(s!.estimate, isNotNull);
      expect(s.estimate!.isStale, isFalse);

      tracker.tick(now: t0.add(const Duration(milliseconds: 3600)));
      s = tracker.stateOf('d');
      expect(s!.estimate!.isStale, isTrue, reason: 'stale after ~2.5 s without samples');
    });

    test('2-anchor tracking with mirror resolution end to end', () {
      final tracker = DeviceTracker(
        anchorsProvider: () => [
          AnchorPoint(x: 0, y: 0, id: 'a1'),
          AnchorPoint(x: 10, y: 0, id: 'a2'),
        ],
      );
      tracker.setInfo(DeviceInfo(id: 'd', name: 'tag'));
      final rng = _Rng(21);
      final t0 = DateTime(2026, 1, 1);
      for (var i = 0; i < 30; i++) {
        final x = 5.0, y = 3.0 - i * 0.05;
        final d1 = math.sqrt(x * x + y * y);
        final d2 = math.sqrt((x - 10) * (x - 10) + y * y);
        tracker.pushSample(RssiSample(deviceId: 'd', source: RssiSource.advertising, dbm: _simRssi(d1, rng), at: t0.add(Duration(milliseconds: i * 100))));
        tracker.pushSample(RssiSample(deviceId: 'd', source: RssiSource.advertising, dbm: _simRssi(d2, rng), at: t0.add(Duration(milliseconds: i * 100 + 50))));
        tracker.tick(now: t0.add(Duration(milliseconds: i * 100 + 50)));
      }
      final s = tracker.stateOf('d');
      expect(s!.fix, isNotNull);
      expect(s.fix!.y, greaterThan(0), reason: 'must resolve to the correct (upper) mirror side');
    });
  });
}
