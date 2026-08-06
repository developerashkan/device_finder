/// Theme for the radar widgets — light (iOS blue) and dark (flagship) look.
///
/// All colors are applied with alpha in the painter; the theme holds the
/// base palette so a host app can restyle the radar without touching the
/// painters.
library;

import 'package:flutter/material.dart';

@immutable
class RadarTheme {
  const RadarTheme({
    required this.background,
    required this.grid,
    required this.ring,
    required this.beam,
    required this.beamFaint,
    required this.blip,
    required this.ellipseFill,
    required this.ellipseStroke,
    required this.pin,
    required this.pinText,
    required this.badgeFill,
    required this.badgeIcon,
    required this.stale,
  });

  /// Neumorphic light — iOS blue on off-white.
  const RadarTheme.light()
      : background = const Color(0xFFE8EEF4), // blue-grey radar circle
        grid = const Color(0x1A0A1F44),
        ring = const Color(0x330A1F44),
        beam = const Color(0xFF007AFF),
        beamFaint = const Color(0x40007AFF),
        blip = const Color(0xFF007AFF),
        ellipseFill = const Color(0x14007AFF),
        ellipseStroke = const Color(0x66007AFF),
        pin = const Color(0xFF007AFF),
        pinText = Colors.white,
        badgeFill = Colors.white,
        badgeIcon = const Color(0xFF007AFF),
        stale = const Color(0xFF9AA5B1);

  /// Flagship dark — the original aesthetic.
  const RadarTheme.dark()
      : background = const Color(0xFF111A26), // blue-grey radar circle
        grid = const Color(0x1FFFFFFF),
        ring = const Color(0x33FFFFFF),
        beam = const Color(0xFF22D3EE),
        beamFaint = const Color(0x6622D3EE),
        blip = const Color(0xFF22D3EE),
        ellipseFill = const Color(0x2222D3EE),
        ellipseStroke = const Color(0x6622D3EE),
        pin = const Color(0xFF22D3EE),
        pinText = const Color(0xFF06121A),
        badgeFill = const Color(0xFF1A2333),
        badgeIcon = const Color(0xFF22D3EE),
        stale = const Color(0xFF64748B);

  final Color background;
  final Color grid;
  final Color ring;
  final Color beam;
  final Color beamFaint;
  final Color blip;
  final Color ellipseFill;
  final Color ellipseStroke;

  /// Teardrop distance pin.
  final Color pin;
  final Color pinText;

  /// Circular device-icon badge.
  final Color badgeFill;
  final Color badgeIcon;

  final Color stale;
}
