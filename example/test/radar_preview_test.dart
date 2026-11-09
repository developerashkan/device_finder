// Renders the bare 3D radar to build/preview/*.png for visual review.
// Run: flutter test test/radar_preview_test.dart --dart-define=CAPTURE=true
import 'package:device_finder/device_finder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/capture.dart';

const _capture = bool.fromEnvironment('CAPTURE');

void main() {
  const targets = [
    RadarTarget(
      id: 'airpods',
      label: 'AirPods Pro',
      meters: 2.4,
      x: -1.2,
      y: 2.0,
      sigmaMeters: 0.5,
      strength: 0.75,
      trend: ProximityTrend.closing,
    ),
    RadarTarget(id: 'tag', label: 'Keys · Tag', meters: 4.8, sigmaMeters: 0.9, strength: 0.45),
    RadarTarget(
      id: 'watch',
      label: 'Galaxy Watch',
      meters: 3.3,
      x: 2.6,
      y: -1.6,
      sigmaMeters: 0.6,
      strength: 0.6,
      trend: ProximityTrend.receding,
    ),
    RadarTarget(id: 'beacon', label: 'Desk beacon', meters: 7.1, strength: 0.25, stale: true),
  ];

  testWidgets('radar preview', (tester) async {
    if (!_capture) return;
    await loadRealFonts(tester);
    usePhoneSurface(tester, logical: const Size(420, 420));
    for (final (name, theme) in [('dark', const Radar3DTheme.dark()), ('light', const Radar3DTheme.light())]) {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: RepaintBoundary(key: key, child: Radar3DView(targets: targets, selectedId: 'airpods', theme: theme, initialTime: 2.15)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
      await capturePng(tester, key, 'build/preview/radar_$name.png', pixelRatio: 2);
    }
  });
}
