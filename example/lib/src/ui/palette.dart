// App design tokens (dark + light), motion tokens and shared helpers.
// Contrast: body/secondary text ≥ 4.5:1 on its surface in both themes.
import 'package:device_finder/device_finder.dart' as df;
import 'package:flutter/material.dart';

@immutable
class Palette {
  const Palette._({
    required this.dark,
    required this.bgTop,
    required this.bgBottom,
    required this.surface,
    required this.surfaceStrong,
    required this.border,
    required this.text,
    required this.textSecondary,
    required this.muted,
    required this.accent,
    required this.ok,
    required this.warn,
    required this.danger,
    required this.radar,
  });

  static const darkPalette = Palette._(
    dark: true,
    bgTop: Color(0xFF071224),
    bgBottom: Color(0xFF02060C),
    surface: Color(0x0FFFFFFF),
    surfaceStrong: Color(0x1AFFFFFF),
    border: Color(0x1FFFFFFF),
    text: Color(0xFFF1F5F9),
    textSecondary: Color(0xFFB4C2D3),
    muted: Color(0xFF8A9AB0),
    accent: Color(0xFF22D3EE),
    ok: Color(0xFF34D399),
    warn: Color(0xFFFBBF24),
    danger: Color(0xFFFB7185),
    radar: df.Radar3DTheme.dark(),
  );

  static const lightPalette = Palette._(
    dark: false,
    bgTop: Color(0xFFF7FAFE),
    bgBottom: Color(0xFFE6EEF8),
    surface: Color(0xCCFFFFFF),
    surfaceStrong: Color(0xFFFFFFFF),
    border: Color(0x1A0F172A),
    text: Color(0xFF0F172A),
    textSecondary: Color(0xFF334155),
    muted: Color(0xFF55657A),
    accent: Color(0xFF0284C7),
    ok: Color(0xFF047857),
    warn: Color(0xFFB45309),
    danger: Color(0xFFBE123C),
    radar: df.Radar3DTheme.light(),
  );

  static Palette of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? darkPalette : lightPalette;

  final bool dark;
  final Color bgTop;
  final Color bgBottom;
  final Color surface;
  final Color surfaceStrong;
  final Color border;
  final Color text;
  final Color textSecondary;
  final Color muted;
  final Color accent;
  final Color ok;
  final Color warn;
  final Color danger;
  final df.Radar3DTheme radar;

  /// Same color the radar uses for this device.
  Color deviceColor(String id) {
    final h = df.RadarTarget(id: id, label: '', meters: 0).stableHash;
    return radar.palette[h % radar.palette.length];
  }
}

abstract final class Motion {
  static const press = Duration(milliseconds: 120);
  static const enter = Duration(milliseconds: 320);
  static const exit = Duration(milliseconds: 200);
  static const stagger = Duration(milliseconds: 45);
  static const value = Duration(milliseconds: 420);
  static const curve = Curves.easeOutCubic;

  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

IconData iconForKind(String? kind) => switch (kind) {
  'headphones' => Icons.headphones_rounded,
  'watch' => Icons.watch_rounded,
  'tag' => Icons.key_rounded,
  'beacon' => Icons.cell_tower_rounded,
  'phone' => Icons.smartphone_rounded,
  _ => Icons.bluetooth_rounded,
};

String labelForKind(String? kind) => switch (kind) {
  'headphones' => 'Headphones',
  'watch' => 'Watch',
  'tag' => 'Tag',
  'beacon' => 'Beacon',
  'phone' => 'Phone',
  _ => 'Bluetooth',
};

String formatMeters(double m) => m < 10 ? m.toStringAsFixed(1) : m.toStringAsFixed(0);
