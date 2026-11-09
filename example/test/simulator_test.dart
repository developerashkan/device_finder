import 'dart:math' as math;

import 'package:device_finder/device_finder.dart' as df;
import 'package:device_finder_example/main.dart';
import 'package:device_finder_example/src/finder_controller.dart';
import 'package:device_finder_example/src/simulator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SimulatedWorld', () {
    test('is deterministic for a seed', () {
      final a = SimulatedWorld(seed: 3, start: DateTime(2026));
      final b = SimulatedWorld(seed: 3, start: DateTime(2026));
      for (var i = 0; i < 20; i++) {
        final sa = a.step(0.1), sb = b.step(0.1);
        expect(sa.map((s) => s.dbm), sb.map((s) => s.dbm));
      }
    });
  });

  group('FinderController (demo)', () {
    test('tracks every device; hub-heard ones are located accurately', () {
      final c = FinderController(autoRun: false);
      addTearDown(c.dispose);
      c.advance(12);
      final world = SimulatedWorld(seed: 7);
      expect(c.tracker.deviceCount, world.devices.length);

      for (final d in world.devices.where((d) => d.heardByHubs)) {
        final s = c.tracker.stateOf(d.id)!;
        expect(s.fix, isNotNull, reason: '${d.name} is heard by 3 hubs');
        // Truth at the controller's clock (3 s warm-up + 12 s).
        final (tx, ty) = d.path(15);
        final err = math.sqrt(math.pow(s.fix!.x - tx, 2) + math.pow(s.fix!.y - ty, 2));
        expect(err, lessThan(2.0), reason: '${d.name} fix error ${err.toStringAsFixed(2)} m');
      }
      for (final d in world.devices.where((d) => !d.heardByHubs)) {
        expect(c.tracker.stateOf(d.id)!.fix, isNull, reason: '${d.name}: phone only → no invented direction');
      }
    });

    test('the beacon goes stale while silent and recovers', () {
      final c = FinderController(autoRun: false);
      addTearDown(c.dispose);
      c.advance(34); // t = 37 s: inside the 31–40 s silence window
      expect(c.tracker.stateOf('sim-beacon')!.estimate!.isStale, isTrue);
      c.advance(6); // t = 43 s: talking again
      expect(c.tracker.stateOf('sim-beacon')!.estimate!.isStale, isFalse);
    });

    test('distances are plausible against the simulated truth', () {
      final c = FinderController(autoRun: false);
      addTearDown(c.dispose);
      c.advance(10);
      final world = SimulatedWorld(seed: 7);
      for (final d in world.devices.where((d) => d.txPower == -59)) {
        final (x, y) = d.path(13);
        final truth = math.sqrt(x * x + y * y);
        final est = c.tracker.stateOf(d.id)!.estimate!.meters;
        expect((est - truth).abs() / truth, lessThan(0.6), reason: '${d.name}: est $est vs truth $truth');
      }
    });
  });

  group('App', () {
    testWidgets('home → locate → back, haptics toggle, no leaks', (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = FinderController(autoRun: false);
      await tester.pumpWidget(DeviceFinderApp(controller: c, themeMode: ThemeMode.dark));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Finder'), findsOneWidget);
      expect(find.text('AirPods Pro'), findsOneWidget);

      await tester.tap(find.text('AirPods Pro'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Proximity'), findsOneWidget);
      expect(find.textContaining('Located by 3 hubs'), findsOneWidget);

      await tester.tap(find.byTooltip('Turn on Geiger haptics'));
      await tester.pump();
      expect(find.byTooltip('Turn off Geiger haptics'), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Nearby'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('distance-only device explains the unknown direction', (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = FinderController(autoRun: false);
      await tester.pumpWidget(DeviceFinderApp(controller: c, themeMode: ThemeMode.light));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Keys'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Direction unknown'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('reduced motion renders a static, valid scene', (tester) async {
      final c = FinderController(autoRun: false);
      await tester.pumpWidget(
        MediaQuery(data: const MediaQueryData(disableAnimations: true, size: Size(393, 852)), child: DeviceFinderApp(controller: c)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(df.Radar3DView), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
