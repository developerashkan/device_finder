// Helpers for rendering real-font, high-resolution PNG screenshots from
// widget tests (deterministic: fixed clock, fixed simulator seed).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads Roboto + Material Icons from the Flutter SDK so screenshots show
/// real text instead of the test font's boxes. Real file I/O, so it runs
/// outside the test's fake-async zone.
Future<void> loadRealFonts(WidgetTester tester) => tester.runAsync(_loadRealFonts);

Future<void> _loadRealFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'] ?? 'C:/dev/flutter';
  final dir = '$root/bin/cache/artifacts/material_fonts';
  Future<ByteData> bytes(String f) async => ByteData.sublistView(await File('$dir/$f').readAsBytes());

  final roboto = FontLoader('Roboto');
  for (final f in ['roboto-regular.ttf', 'roboto-medium.ttf', 'roboto-bold.ttf', 'roboto-black.ttf', 'roboto-light.ttf']) {
    roboto.addFont(bytes(f));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')..addFont(bytes('materialicons-regular.otf'));
  await icons.load();
}

/// Captures the first [RepaintBoundary] keyed [key] to a PNG at [pixelRatio].
Future<void> capturePng(WidgetTester tester, Key key, String path, {double pixelRatio = 3}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

/// Phone-sized test surface (logical size × device pixel ratio).
void usePhoneSurface(WidgetTester tester, {Size logical = const Size(393, 852)}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = logical;
  addTearDown(tester.view.reset);
}
