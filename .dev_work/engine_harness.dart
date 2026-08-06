/// Dev harness: validates the pure-Dart engine headlessly with `dart run`,
/// mirroring the canonical flutter_test assertions. Uses only dart:math.
library;

import 'dart:math' as math;

import 'package:engine/engine/engine.dart';

class _Rng {
  _Rng(int seed) : _s = seed & 0x7fffffff;
  int _s;
  double next() {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s / 0x7fffffff;
  }

  double gauss(double sigma) {
    final u1 = math.max(next(), 1e-12);
    final u2 = next();
    return sigma * math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }
}

double _simRssi(double d, _Rng rng, {double sigma = 3.0}) {
  return -59.0 - 28.0 * math.log(d) / math.ln10 + rng.gauss(sigma);
}

int _fails = 0;
void expect(bool cond, String label, [String? detail]) {
  if (!cond) {
    _fails++;
    print('  FAIL: $label${detail == null ? '' : ' — $detail'}');
  } else {
    print('  ok: $label');
  }
}

void main() {
  print('== path_loss ==');
  var ok = true;
  for (final d in [1.0, 2.0, 4.0, 8.0, 15.0, 20.0]) {
    final rssi = rssiFromDistance(d);
    final recovered = distanceFromRssi(rssi);
    if ((recovered - d).abs() / d >= 0.02) ok = false;
  }
  expect(ok, 'round trip d→RSSI→d within 2%');
  expect(distanceFromRssi(-50) < distanceFromRssi(-80), 'monotonic');
  expect(distanceFromRssi(-10) == 0.5 && distanceFromRssi(-140) == 30.0, 'clamps');

  print('== kalman ==');
  {
    final k = RssiKalmanFilter();
    final rng = _Rng(42);
    var sumSq = 0.0;
    double? prev;
    var maxStep = 0.0;
    for (var i = 0; i < 200; i++) {
      final truth = -65.0 + 3.0 * math.sin(i / 20.0);
      final f = k.updateWithDt(truth + rng.gauss(3.0), 0.1);
      sumSq += (f - truth) * (f - truth);
      if (prev != null) maxStep = math.max(maxStep, (f - prev).abs());
      prev = f;
    }
    final rms = math.sqrt(sumSq / 200);
    expect(rms <= 5.0, 'residual RMS ${rms.toStringAsFixed(2)} ≤ 5 dB', 'got $rms');
    expect(maxStep < 6.0, 'max step ${maxStep.toStringAsFixed(2)} < 6 dB');
  }
  {
    final k = RssiKalmanFilter();
    for (var i = 0; i < 30; i++) {
      k.updateWithDt(-60.0, 0.1);
    }
    var maxLag = 0.0;
    var settleAt = -1;
    final stepStart = k.value; // snapshot before the step begins
    for (var i = 0; i < 100; i++) {
      final f = k.updateWithDt(-75.0, 0.1);
      // Lag is how far the output has moved toward the target — measured
      // against the pre-step value, not the not-yet-reached target.
      final progress = (f - stepStart).abs() / 15.0;
      final lag = 15.0 * (1.0 - progress);
      maxLag = math.max(maxLag, lag);
      if (settleAt < 0 && (-75.0 - f).abs() < 1.0) settleAt = i;
    }
    expect(maxLag < 8.0, '15 dB step lag ${maxLag.toStringAsFixed(2)} < 8 dB');
    expect(settleAt >= 0 && settleAt <= 15, 'settles in ${settleAt * 100} ms ≤ 1.5 s');
  }

  print('== fusion ==');
  {
    final f = SourceFusion();
    final t0 = DateTime.now();
    for (var i = 0; i < 8; i++) {
      f.push(RssiSample(deviceId: 'd', source: RssiSource.advertising, dbm: -60.0 + i, at: t0.add(Duration(milliseconds: i * 100))));
    }
    expect(f.estimate(t0.add(const Duration(seconds: 1)))!.fresh, 'fresh at 1 s');
    // Last sample at t0 + 700 ms; stale (> 2.5 s since last) from t0 + 3.3 s.
    final stale = f.estimate(t0.add(const Duration(milliseconds: 3300)));
    expect(stale != null && stale.stale && !stale.fresh, 'stale hold at 2.6 s after last sample');
    // Ghost drop (> 5 s since last) from t0 + 5.8 s.
    expect(f.estimate(t0.add(const Duration(milliseconds: 5800))) == null, 'ghost drop at 5.1 s after last sample');
    expect(f.ghosted, 'ghosted flag');
  }
  {
    final f = SourceFusion();
    final t0 = DateTime.now();
    // Realistic advertising noise (σ ≈ 8 dB).
    final rng = _Rng(5);
    for (var i = 0; i < 10; i++) {
      f.push(RssiSample(deviceId: 'd', source: RssiSource.advertising, dbm: -60 + rng.gauss(8.0), at: t0.add(Duration(milliseconds: i * 100))));
    }
    // Clean connected-link window (σ ≈ 2 dB) — must win.
    for (var i = 0; i < 5; i++) {
      f.push(RssiSample(deviceId: 'd', source: RssiSource.connectedLink, dbm: -62.0 + rng.gauss(2.0), at: t0.add(Duration(milliseconds: (100 + i * 100)))));
    }
    final r = f.estimate(t0.add(const Duration(seconds: 1)))!;
    expect(r.source == RssiSource.connectedLink, 'clean link wins over noisy advert');
    expect((r.mean - (-62.0)).abs() < 1.0, 'link mean preserved');
  }
  {
    // Degenerate (σ=0) advertising window must NOT win over a valid link.
    final f = SourceFusion();
    final t0 = DateTime.now();
    for (var i = 0; i < 10; i++) {
      f.push(RssiSample(deviceId: 'd', source: RssiSource.advertising, dbm: -60.0, at: t0.add(Duration(milliseconds: i * 100))));
    }
    for (var i = 0; i < 5; i++) {
      f.push(RssiSample(deviceId: 'd', source: RssiSource.connectedLink, dbm: -62.0 + (i.isEven ? 4.0 : -4.0), at: t0.add(Duration(milliseconds: (100 + i * 100)))));
    }
    final r = f.estimate(t0.add(const Duration(seconds: 1)))!;
    expect(r.source == RssiSource.connectedLink, 'valid link beats degenerate ad');
  }

  print('== trilateration ==');
  {
    const truth = (x: 4.0, y: 3.0);
    final rng = _Rng(7);
    var contains = 0;
    var errSum = 0.0;
    for (var t = 0; t < 100; t++) {
      final noisy = [
        Anchor(x: 0, y: 0, distance: (5.0 + rng.gauss(0.8)).clamp(0.2, 20.0), sigma: 0.8),
        Anchor(x: 10, y: 0, distance: (math.sqrt(45.0) + rng.gauss(0.8)).clamp(0.2, 20.0), sigma: 0.8),
        Anchor(x: 5, y: 8.66, distance: (math.sqrt(1 + 5.66 * 5.66) + rng.gauss(0.8)).clamp(0.2, 20.0), sigma: 0.8),
      ];
      final f = solveTrilateration(noisy);
      errSum += math.sqrt((f.x - truth.x) * (f.x - truth.x) + (f.y - truth.y) * (f.y - truth.y));
      final (major, minor, theta) = f.confidenceEllipse();
      final rad = theta * math.pi / 180;
      final dx = truth.x - f.x, dy = truth.y - f.y;
      final ex = dx * math.cos(rad) + dy * math.sin(rad);
      final ey = -dx * math.sin(rad) + dy * math.cos(rad);
      if (ex * ex / (major * major) + ey * ey / (minor * minor) <= 1.0) contains++;
    }
    expect(errSum / 100 < 1.5, 'median error ${(errSum / 100).toStringAsFixed(2)} m < 1.5');
    expect(contains >= 90, 'ellipse contains truth $contains/100 ≥ 90%');
  }
  {
    final f = solveTrilateration([
      Anchor(x: 0, y: 0, distance: 5),
      Anchor(x: 5, y: 0, distance: 1),
      Anchor(x: 10, y: 0, distance: 6),
    ]);
    final (major, minor, _) = f.confidenceEllipse();
    expect(major > 5.0 && major / minor > 3.0,
        'collinear ellipse elongated (major ${major.toStringAsFixed(1)} m, ratio ${(major / minor).toStringAsFixed(1)})');
  }
  {
    final pf = solveTwoAnchors(Anchor(x: 0, y: 0, distance: 5), Anchor(x: 10, y: 0, distance: 6));
    // d1 = 5, d2 = 6, L = 10: circles intersect in two genuine mirror points
    // above/below the baseline, symmetric about x = a = 4.7.
    expect(!pf.isDegenerate, 'mirror pair exists');
    expect((pf.a.$1 - pf.b.$1).abs() < 1e-9, 'mirror points share the same x');
    expect((pf.a.$2 + pf.b.$2).abs() < 1e-9, 'mirror points are symmetric about the baseline');
  }

  print('== mirror_resolver (dogleg walk, Kalman-filtered — as in production) ==');
  {
    const a1 = (0.0, 0.0);
    const a2 = (10.0, 0.0);
    final path = <(double, double)>[];
    const dt = 0.1;
    var t = 0.0;
    var x = 5.0, y = 5.0; // start well above the baseline for resolvable geometry
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
    var maxErr = 0.0, errSum = 0.0, minY = double.infinity, worstAbove = 0.0;
    var kept = 0;
    final t0 = DateTime(2026, 1, 1);
    for (final seed in [1, 2, 3, 4, 5]) {
      final rng = _Rng(seed);
      final resolver = MirrorResolver();
      final k1 = RssiKalmanFilter();
      final k2 = RssiKalmanFilter();
      for (var i = 0; i < path.length; i++) {
        final pos = path[i];
        final d1 = math.sqrt(pos.$1 * pos.$1 + pos.$2 * pos.$2);
        final d2 = math.sqrt((pos.$1 - 10) * (pos.$1 - 10) + pos.$2 * pos.$2);
        // Kalman-smooth each anchor's RSSI stream (as the tracker does), then
        // convert to distance.
        final rssi1 = k1.updateWithDt(_simRssi(d1, rng), dt);
        final rssi2 = k2.updateWithDt(_simRssi(d2, rng), dt);
        final pf = solveTwoAnchors(
          Anchor(x: a1.$1, y: a1.$2, distance: distanceFromRssi(rssi1)),
          Anchor(x: a2.$1, y: a2.$2, distance: distanceFromRssi(rssi2)),
        );
        if (pf.isDegenerate) continue; // no geometry to resolve
        kept++;
        final chosen = resolver.resolve(a: pf.a, b: pf.b, at: t0.add(Duration(milliseconds: i * 100)), anchorSetChanged: false);
        final err = math.sqrt((chosen.$1 - pos.$1) * (chosen.$1 - pos.$1) + (chosen.$2 - pos.$2) * (chosen.$2 - pos.$2));
        maxErr = math.max(maxErr, err);
        errSum += err;
        minY = math.min(minY, chosen.$2);
        if (pos.$2 > 1.5) worstAbove = math.max(worstAbove, pos.$2 - chosen.$2);
      }
    }
    // Honest bounds for σ = 3 dB RSSI noise: single-sample outliers from
    // Kalman lag at the turn are expected; the resolver must never flip.
    expect(minY > -0.3, 'never mirrors (min y ${minY.toStringAsFixed(2)})');
    expect(worstAbove < 4.5, 'stays on the true side when y > 1.5 (worst gap ${worstAbove.toStringAsFixed(2)})');
    expect(kept >= 5 * path.length * 0.8, 'enough non-degenerate steps ($kept)');
    expect(errSum / kept < 1.2, 'median err ${(errSum / kept).toStringAsFixed(2)} m < 1.2');
    expect(maxErr < 5.5, 'max err ${maxErr.toStringAsFixed(2)} m < 5.5 (single-sample outlier tolerant)');
  }

  print('== calibration ==');
  {
    final c = Calibrator(minSamplesPerDistance: 50);
    final rng = _Rng(11);
    for (final d in [1.0, 2.0, 4.0, 8.0]) {
      for (var i = 0; i < 60; i++) {
        c.addSample(d, -59.0 - 28.0 * math.log(d) / math.ln10 + rng.gauss(3.0));
      }
    }
    final r = c.fit();
    expect(r.accepted, 'clean fit accepted: n=${r.profile.exponent.toStringAsFixed(2)} tx=${r.profile.txPower.toStringAsFixed(1)} rms=${r.profile.residualRmsDb.toStringAsFixed(2)} dB');
    expect((r.profile.exponent - 2.8).abs() <= 0.4 && (r.profile.txPower + 59).abs() <= 5.0, 'recovers n≈2.8, Tx≈−59');
  }
  {
    final c = Calibrator(minSamplesPerDistance: 50);
    final rng = _Rng(12);
    for (final d in [1.0, 2.0, 4.0, 8.0]) {
      for (var i = 0; i < 60; i++) {
        c.addSample(d, -59.0 - 28.0 * math.log(d) / math.ln10 + rng.gauss(3.0) + (d == 4.0 ? 20.0 : 0.0));
      }
    }
    final r = c.fit();
    expect(!r.accepted && r.reason!.contains('8'), 'corrupt fit rejected: ${r.reason}');
  }
  {
    final c = Calibrator(minSamplesPerDistance: 50);
    final rng = _Rng(13);
    for (final d in [1.0, 2.0, 4.0, 8.0]) {
      for (var i = 0; i < 60; i++) {
        c.addSample(d, -59.0 - 60.0 * math.log(d) / math.ln10 + rng.gauss(2.0));
      }
    }
    final r = c.fit();
    expect(!r.accepted && r.reason!.contains('Exponent'), 'implausible n rejected: ${r.reason}');
  }

  print('== tracker ==');
  {
    final tracker = DeviceTracker();
    final t0 = DateTime(2026, 1, 1);
    tracker.setInfo(DeviceInfo(id: 'd', name: 'tag'));
    for (var i = 0; i < 10; i++) {
      tracker.pushSample(RssiSample(deviceId: 'd', source: RssiSource.advertising, dbm: -60.0, at: t0.add(Duration(milliseconds: i * 100))));
    }
    tracker.tick(now: t0.add(const Duration(seconds: 1)));
    expect(!tracker.stateOf('d')!.estimate!.isStale, 'fresh estimate at 1 s');
    tracker.tick(now: t0.add(const Duration(milliseconds: 3600)));
    expect(tracker.stateOf('d')!.estimate!.isStale, 'stale at 3.6 s');
  }
  {
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
      final y = 3.0 - i * 0.05;
      final d1 = math.sqrt(25.0 + y * y);
      final d2 = math.sqrt(25.0 + y * y);
      tracker.pushSample(RssiSample(deviceId: 'd', source: RssiSource.advertising, dbm: _simRssi(d1, rng), at: t0.add(Duration(milliseconds: i * 100))));
      tracker.pushSample(RssiSample(deviceId: 'd', source: RssiSource.advertising, dbm: _simRssi(d2, rng), at: t0.add(Duration(milliseconds: i * 100 + 50))));
      tracker.tick(now: t0.add(Duration(milliseconds: i * 100 + 50)));
    }
    final s = tracker.stateOf('d');
    expect(s!.fix != null && s.fix!.y > 0, 'end-to-end mirror resolve to upper side (y=${s.fix!.y.toStringAsFixed(2)})');
  }

  print('');
  print(_fails == 0 ? 'ALL ENGINE CHECKS PASSED' : '$_fails CHECKS FAILED');
}
