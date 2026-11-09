import 'dart:math' as math;

import 'package:device_finder/device_finder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Radar3DCamera', () {
    test('top-down view maps forward to screen-up and right to screen-right', () {
      final cam = Radar3DCamera(pitch: Radar3DCamera.maxPitch);
      final fwd = cam.project(0, 1, 0);
      final right = cam.project(1, 0, 0);
      expect(fwd.y, lessThan(-0.9));
      expect(fwd.x.abs(), lessThan(0.05));
      expect(right.x, greaterThan(0.9));
    });

    test('tilted view: near side is larger and closer than the far side', () {
      final cam = Radar3DCamera(pitch: 50 * math.pi / 180);
      final near = cam.project(0, -1, 0), far = cam.project(0, 1, 0);
      expect(near.depth, lessThan(far.depth));
      expect(near.scale, greaterThan(far.scale));
      expect(cam.project(0, 0, 0.5).y, lessThan(0), reason: 'up is up on screen');
    });

    test('pitch is clamped to the readable range', () {
      final cam = Radar3DCamera(pitch: 0);
      expect(cam.pitch, Radar3DCamera.minPitch);
      cam.set(0, 3);
      expect(cam.pitch, Radar3DCamera.maxPitch);
    });

    test('disc bounds are yaw-independent', () {
      final a = Radar3DCamera(yaw: 0, pitch: 1).discBounds();
      final b = Radar3DCamera(yaw: 1.3, pitch: 1).discBounds();
      expect((a.$3 - a.$1) - (b.$3 - b.$1), closeTo(0, 0.02));
    });
  });

  group('Radar3DController', () {
    test('a sweep revolution pings every live target exactly once', () {
      final c = Radar3DController(theme: const Radar3DTheme.dark(), sweepPeriodSeconds: 2);
      c.targets = const [
        RadarTarget(id: 'a', label: 'A', meters: 2, x: 1, y: 1),
        RadarTarget(id: 'b', label: 'B', meters: 3, x: -2, y: -1),
        RadarTarget(id: 'lost', label: 'L', meters: 3, x: 0, y: 2, stale: true),
      ];
      final hits = <String, int>{};
      var last = <String, double>{};
      for (var i = 0; i < 120; i++) {
        c.advance(1 / 60);
        for (final e in c.pings.entries) {
          if (last[e.key] != e.value) hits[e.key] = (hits[e.key] ?? 0) + 1;
        }
        last = Map.of(c.pings);
      }
      expect(hits['a'], 1);
      expect(hits['b'], 1);
      expect(hits.containsKey('lost'), isFalse, reason: 'stale targets never ping');
      c.dispose();
    });

    test('adaptive range eases to a nice value covering the targets', () {
      final c = Radar3DController(theme: const Radar3DTheme.dark());
      c.targets = const [RadarTarget(id: 'far', label: 'F', meters: 9)];
      expect(c.targetRange, 12);
      for (var i = 0; i < 240; i++) {
        c.advance(1 / 60);
      }
      expect(c.range, closeTo(12, 0.2));
      c.fixedRange = 5;
      expect(c.targetRange, 5);
      c.dispose();
    });

    test('distance-only targets orbit; positioned ones keep their bearing', () {
      const fixed = RadarTarget(id: 'f', label: 'F', meters: 2, x: 1, y: 0);
      const ring = RadarTarget(id: 'r', label: 'R', meters: 2);
      expect(fixed.bearingAt(0), closeTo(math.pi / 2, 1e-9));
      expect(fixed.bearingAt(10), fixed.bearingAt(0));
      expect(ring.bearingAt(10), isNot(ring.bearingAt(0)));
    });
  });

  group('Radar3DView', () {
    const targets = [
      RadarTarget(id: 'a', label: 'AirPods', meters: 2, x: 0, y: 2, strength: 0.8),
      RadarTarget(id: 'b', label: 'Tag', meters: 4, strength: 0.4),
    ];

    testWidgets('animates, survives drag/double-tap, disposes cleanly', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Radar3DView(targets: targets))));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.drag(find.byType(Radar3DView), const Offset(120, -40));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byType(Radar3DView));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.byType(Radar3DView));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping an orb reports its id', (tester) async {
      String? tapped;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: Radar3DView(targets: targets, onTargetTap: (id) => tapped = id, autoOrbit: false),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 16));
      final state = tester.state(find.byType(Radar3DView));
      // Hit regions are published by the painter after the first paint.
      final hits = (state as dynamic).debugHits as List<Radar3DHit>;
      final a = hits.firstWhere((h) => h.id == 'a');
      final origin = tester.getTopLeft(find.byType(Radar3DView));
      await tester.tapAt(origin + a.center);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tapped, 'a');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('reduced motion: no ticker, still paints and summarizes', (tester) async {
      await tester.pumpWidget(const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: MaterialApp(home: Scaffold(body: Radar3DView(targets: targets))),
      ));
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
      expect(find.bySemanticsLabel(RegExp('Radar. 2 devices. Nearest: AirPods')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('empty and non-finite input never throws', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Radar3DView(targets: [
            RadarTarget(id: 'x', label: 'X', meters: double.infinity),
            RadarTarget(id: 'y', label: '', meters: 0),
          ]),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Radar3DView(targets: []))));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('RadarTarget.fromState', () {
    test('needs an estimate; uses fix when present; trims names', () {
      final info = DeviceInfo(id: 'AA:BB:CC:DD:EE:FF', name: '  ');
      expect(RadarTarget.fromState(TrackedDeviceState(info: info)), isNull);
      final s = TrackedDeviceState(
        info: info,
        estimate: DistanceEstimate(
          meters: 3,
          sigmaMeters: 0.5,
          rssiDb: -70,
          source: RssiSource.advertising,
          isStale: false,
          at: DateTime(2026),
        ),
      );
      final t = RadarTarget.fromState(s)!;
      expect(t.hasPosition, isFalse);
      expect(t.label, '…EE:FF');
    });
  });
}
