import 'package:device_finder/device_finder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RadarScene', () {
    test('advance lights every sector over a full revolution (no gaps)', () {
      final scene = RadarScene(sectors: 360, periodSeconds: 1.0);
      final lit = <int>{};
      // 60 fps for one second = one revolution.
      for (var i = 0; i < 60; i++) {
        scene.advance(1 / 60);
        final beam = scene.phase / 100.0;
        lit.add(beam.floor() % 360);
      }
      // With accumulation, ~60 distinct sectors get lit; the beam should
      // have moved ~1.0° per frame.
      expect(lit.length, greaterThanOrEqualTo(55));
      expect(scene.phase, lessThan(36000));
      expect(scene.phase, greaterThanOrEqualTo(0));
    });

    test('brightness decays after the beam passes', () {
      final scene = RadarScene(sectors: 360, periodSeconds: 2.2, decayPerSecond: 1.6);
      scene.advance(1 / 60);
      final litIdx = (scene.phase / 100.0).floor() % 360;
      expect(scene.brightness[litIdx], greaterThan(0.5));
      // Advance well past it (half a revolution at 2.2 s/rev ≈ 66 frames).
      for (var i = 0; i < 70; i++) {
        scene.advance(1 / 60);
      }
      expect(scene.brightness[litIdx], lessThan(0.5));
    });

    test('advance never leaves the phase range', () {
      final scene = RadarScene();
      for (var i = 0; i < 1000; i++) {
        scene.advance(1 / 60);
      }
      expect(scene.phase, inInclusiveRange(0, 35999));
    });
  });

  group('SignalMeter', () {
    test('maps RSSI to strength', () {
      expect(strengthFromRssi(-40), closeTo(1.0, 0.001));
      expect(strengthFromRssi(-100), closeTo(0.0, 0.001));
      expect(strengthFromRssi(-70), closeTo(0.5, 0.001));
    });
  });

  group('RadarView', () {
    testWidgets('paints without error and disposes cleanly', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: RadarView()));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
    });
  });

  group('EllipseMap', () {
    testWidgets('renders a fix with confidence ellipse', (tester) async {
      final fix = PositionFix(
        x: 1.5,
        y: 2.0,
        covXX: 0.5,
        covYY: 0.25,
        covXY: 0.1,
        quality: 0.6,
        status: FixStatus.fresh,
        at: DateTime.now(),
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: EllipseMap(fix: fix)),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
