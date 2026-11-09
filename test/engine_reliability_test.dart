// Reliability tests for the 0.2.0 engine fixes: per-observer trilateration,
// grouping without ghosts, profile application, staleness, input hygiene.
import 'dart:math' as math;

import 'package:device_finder/device_finder.dart';
import 'package:flutter_test/flutter_test.dart';

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

double _rssiAt(double d, _Rng rng, {double sigma = 2.0}) =>
    -59.0 - 28.0 * math.log(math.max(d, 0.5)) / math.ln10 + rng.gauss(sigma);

final _t0 = DateTime(2026, 1, 1);
DateTime _at(int ms) => _t0.add(Duration(milliseconds: ms));

RssiSample _s(String id, double dbm, int ms, {String observer = 'self'}) =>
    RssiSample(deviceId: id, observerId: observer, source: RssiSource.advertising, dbm: dbm, at: _at(ms));

void main() {
  group('multi-observer trilateration', () {
    final anchors = [
      AnchorPoint(x: 0, y: 0, id: 'a'),
      AnchorPoint(x: 8, y: 0, id: 'b'),
      AnchorPoint(x: 0, y: 8, id: 'c'),
      AnchorPoint(x: 8, y: 8, id: 'd'),
    ];

    test('per-anchor distances recover the true position (< 1.5 m)', () {
      const truth = (3.0, 5.0);
      final errors = <double>[];
      for (final seed in [1, 2, 3, 4, 5, 6]) {
        final tracker = DeviceTracker(anchorsProvider: () => anchors);
        final rng = _Rng(seed);
        for (var i = 0; i < 40; i++) {
          for (final a in anchors) {
            final d = math.sqrt(math.pow(truth.$1 - a.x, 2) + math.pow(truth.$2 - a.y, 2));
            tracker.pushSample(_s('tag', _rssiAt(d, rng), i * 100, observer: a.id));
          }
          tracker.tick(now: _at(i * 100 + 50));
        }
        final fix = tracker.stateOf('tag')!.fix!;
        expect(fix.status, FixStatus.fresh);
        expect(fix.ambiguity, 0);
        errors.add(math.sqrt(math.pow(fix.x - truth.$1, 2) + math.pow(fix.y - truth.$2, 2)));
      }
      errors.sort();
      expect(errors[errors.length ~/ 2], lessThan(1.5), reason: 'median error over seeds');
      expect(errors.every((e) => e.isFinite), isTrue);
    });

    test('samples only from this phone never invent a position', () {
      final tracker = DeviceTracker(anchorsProvider: () => anchors);
      for (var i = 0; i < 20; i++) {
        tracker.pushSample(_s('tag', -65, i * 100));
        tracker.tick(now: _at(i * 100 + 50));
      }
      final s = tracker.stateOf('tag')!;
      expect(s.estimate, isNotNull);
      expect(s.fix, isNull, reason: 'one observer cannot know direction');
    });

    test('losing anchors keeps the last fix but marks it stale', () {
      final tracker = DeviceTracker(anchorsProvider: () => anchors);
      final rng = _Rng(9);
      for (var i = 0; i < 20; i++) {
        for (final a in anchors) {
          tracker.pushSample(_s('tag', _rssiAt(4, rng), i * 100, observer: a.id));
        }
        tracker.pushSample(_s('tag', _rssiAt(4, rng), i * 100));
        tracker.tick(now: _at(i * 100 + 50));
      }
      expect(tracker.stateOf('tag')!.fix!.status, FixStatus.fresh);
      // Anchors go silent; the phone keeps hearing the device.
      for (var i = 20; i < 80; i++) {
        tracker.pushSample(_s('tag', _rssiAt(4, rng), i * 100));
        tracker.tick(now: _at(i * 100 + 50));
      }
      final s = tracker.stateOf('tag')!;
      expect(s.estimate!.isStale, isFalse);
      expect(s.fix!.status, FixStatus.stale);
    });
  });

  group('grouping and lifecycle', () {
    test('samples before setInfo do not leave a ghost device', () {
      final tracker = DeviceTracker();
      for (var i = 0; i < 10; i++) {
        tracker.pushSample(_s('mac-1', -60, i * 100));
      }
      tracker.setInfo(DeviceInfo(id: 'mac-1', name: 'AirTag'));
      tracker.tick(now: _at(1000));
      final all = tracker.states.toList();
      expect(all, hasLength(1));
      expect(all.single.info.name, 'AirTag');
      expect(all.single.estimate, isNotNull, reason: 'earlier samples are carried over');
    });

    test('devices without info expose their own id (never empty)', () {
      final tracker = DeviceTracker();
      tracker.pushSample(_s('mac-9', -60, 0));
      expect(tracker.states.single.info.id, 'mac-9');
    });

    test('rotating MACs with one name merge; renaming one keeps the other', () {
      final tracker = DeviceTracker();
      tracker.setInfo(DeviceInfo(id: 'm1', name: 'Tag'));
      tracker.setInfo(DeviceInfo(id: 'm2', name: 'Tag'));
      for (var i = 0; i < 10; i++) {
        tracker.pushSample(_s('m1', -60, i * 100));
        tracker.pushSample(_s('m2', -62, i * 100 + 50));
      }
      tracker.tick(now: _at(1000));
      expect(tracker.deviceCount, 1);

      tracker.setInfo(DeviceInfo(id: 'm1', name: 'Other'));
      expect(tracker.deviceCount, 2);
      expect(tracker.stateOf('m2')!.samples, isNotEmpty, reason: 'shared group keeps its data');
    });

    test('forget by any grouped id removes the device and its mappings', () {
      final tracker = DeviceTracker();
      tracker.setInfo(DeviceInfo(id: 'm1', name: 'Tag'));
      tracker.setInfo(DeviceInfo(id: 'm2', name: 'Tag'));
      tracker.pushSample(_s('m1', -60, 0));
      tracker.forget('m2');
      expect(tracker.deviceCount, 0);
      expect(tracker.stateOf('m1'), isNull);
      tracker.pushSample(_s('m1', -60, 100));
      expect(tracker.stateOf('m1')!.info.id, 'm1', reason: 'stale mapping removed');
    });

    test('applyProfile changes live distances', () {
      final tracker = DeviceTracker();
      for (var i = 0; i < 10; i++) {
        tracker.pushSample(_s('d', -70, i * 100));
      }
      tracker.tick(now: _at(1000));
      final before = tracker.stateOf('d')!.estimate!.meters;
      final ok = tracker.applyProfile(
        'd',
        CalibrationProfile(txPower: -50, exponent: 2.0, residualRmsDb: 1, calibratedAt: _t0),
      );
      tracker.pushSample(_s('d', -70, 1100));
      tracker.tick(now: _at(1150));
      expect(ok, isTrue);
      expect(tracker.stateOf('d')!.estimate!.meters, greaterThan(before));
      expect(tracker.applyProfile('nope', CalibrationProfile.defaults), isFalse);
    });

    test('one tick notifies listeners at most once', () {
      final tracker = DeviceTracker();
      for (final id in ['a', 'b', 'c']) {
        for (var i = 0; i < 5; i++) {
          tracker.pushSample(_s(id, -60, i * 100));
        }
      }
      var calls = 0;
      tracker.stateNotifier.addListener(() => calls++);
      tracker.tick(now: _at(500));
      expect(calls, 1);
    });

    test('stale signal clears the proximity trend', () {
      final tracker = DeviceTracker();
      for (var i = 0; i < 20; i++) {
        tracker.pushSample(_s('d', -80 + i.toDouble(), i * 100));
        tracker.tick(now: _at(i * 100 + 50));
      }
      expect(tracker.stateOf('d')!.trend, ProximityTrend.closing);
      tracker.tick(now: _at(6000));
      expect(tracker.stateOf('d')!.trend, ProximityTrend.unknown);
    });
  });

  group('input hygiene', () {
    test('NaN / absurd RSSI never reaches the filters', () {
      final tracker = DeviceTracker();
      tracker.pushSample(_s('d', double.nan, 0));
      tracker.pushSample(_s('d', double.infinity, 10));
      tracker.pushSample(_s('d', 500, 20));
      expect(tracker.deviceCount, 0);
    });

    test('Kalman ignores duplicate and out-of-order timestamps', () {
      final k = RssiKalmanFilter();
      k.update(-60, _at(0));
      k.update(-60, _at(100));
      final v = k.value;
      k.update(-20, _at(100)); // duplicate
      k.update(-20, _at(50)); // out of order
      expect(k.value, v);
    });

    test('confidence ellipse is never NaN for near-singular covariance', () {
      final fix = PositionFix(
        x: 0,
        y: 0,
        covXX: 1,
        covYY: 1,
        covXY: 1 + 1e-12,
        quality: 1,
        status: FixStatus.fresh,
        at: _t0,
      );
      final (major, minor, theta) = fix.confidenceEllipse();
      expect(major.isNaN || minor.isNaN || theta.isNaN, isFalse);
    });
  });

  group('GeigerHaptics', () {
    test('ticks faster when closer, silences on stale data and on stop', () {
      var now = 0;
      var ticks = 0;
      final h = GeigerHaptics(onTick: () => ticks++, clockMs: () => now);
      h.start();
      int run(double meters, int ms) {
        final before = ticks;
        for (var t = 0; t < ms; t += 40) {
          now += 40;
          h.update(meters);
          h.poll();
        }
        return ticks - before;
      }

      final far = run(10, 4000);
      final near = run(0.5, 4000);
      expect(near, greaterThan(far * 3));

      // Stale: no more updates → silent after staleAfter (3 s).
      final before = ticks;
      for (var t = 0; t < 6000; t += 40) {
        now += 40;
        h.poll();
      }
      expect(ticks - before, lessThan(40), reason: 'stops within ~3 s of the last update');
      final afterStale = ticks;
      now += 2000;
      h.poll();
      expect(ticks, afterStale);

      h.stop();
      final afterStop = ticks;
      now += 1000;
      h.update(0.5);
      h.poll();
      expect(ticks, afterStop, reason: 'stopped means silent');
      h.dispose();
    });
  });
}
