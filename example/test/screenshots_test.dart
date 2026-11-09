// Renders the README screenshots from the real app with real fonts.
//
//   cd example
//   flutter test test/screenshots_test.dart --dart-define=CAPTURE=true
//
// Writes ../assets/screenshots/*.png (3x) and build/frames/*.png (GIF frames).
import 'package:device_finder_example/main.dart';
import 'package:device_finder_example/src/finder_controller.dart';
import 'package:device_finder_example/src/ui/components.dart';
import 'package:device_finder_example/src/ui/locate_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/capture.dart';

const _capture = bool.fromEnvironment('CAPTURE');
const _out = '../assets/screenshots';

void main() {
  Future<void> shot(WidgetTester tester, {required String name, required ThemeMode mode, String? locate, double settle = 14}) async {
    final c = FinderController(autoRun: false);
    c.advance(settle);
    final key = GlobalKey();
    final Widget app =
        locate == null
            ? DeviceFinderApp(controller: c, themeMode: mode, radarInitialTime: 2.3)
            : _LocateHost(controller: c, deviceId: locate, mode: mode);
    await tester.pumpWidget(RepaintBoundary(key: key, child: app));
    // Let entrance animations finish (radar keeps animating; that's fine).
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await capturePng(tester, key, '$_out/$name.png');
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('screenshots', (tester) async {
    if (!_capture) return;
    await loadRealFonts(tester);
    usePhoneSurface(tester);
    await shot(tester, name: 'home_dark', mode: ThemeMode.dark);
    await shot(tester, name: 'locate_dark', mode: ThemeMode.dark, locate: 'sim-airpods');
    await shot(tester, name: 'home_light', mode: ThemeMode.light);
    await shot(tester, name: 'locate_light', mode: ThemeMode.light, locate: 'sim-keys');
  });

  testWidgets('radar animation frames', (tester) async {
    if (!_capture) return;
    await loadRealFonts(tester);
    usePhoneSurface(tester, logical: const Size(393, 852));
    final c = FinderController(autoRun: false);
    c.advance(14);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: key, child: DeviceFinderApp(controller: c, themeMode: ThemeMode.dark)));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    // 3.2 s sweep period → 48 frames at 15 fps = one full revolution.
    for (var f = 0; f < 48; f++) {
      for (var k = 0; k < 4; k++) {
        c.advance(1 / 60);
        await tester.pump(const Duration(milliseconds: 16, microseconds: 667));
      }
      await capturePng(tester, key, 'build/frames/f${f.toString().padLeft(3, '0')}.png', pixelRatio: 1.25);
    }
    await tester.pumpWidget(const SizedBox());
  });
}

class _LocateHost extends StatelessWidget {
  const _LocateHost({required this.controller, required this.deviceId, required this.mode});
  final FinderController controller;
  final String deviceId;
  final ThemeMode mode;

  @override
  Widget build(BuildContext context) {
    // Reuse the app's themes, then open the locate screen directly.
    return DeviceFinderApp(
      controller: controller,
      themeMode: mode,
      home: AppBackground(child: LocateScreen(controller: controller, deviceId: deviceId, radarInitialTime: 1.4)),
    );
  }
}
