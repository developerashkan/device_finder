/// Colors for [Radar3DView] — a holographic dark look and a clean light one.
library;

import 'package:flutter/material.dart';

@immutable
class Radar3DTheme {
  const Radar3DTheme({
    required this.backgroundCenter,
    required this.backgroundEdge,
    required this.discCenter,
    required this.discEdge,
    required this.grid,
    required this.ring,
    required this.accent,
    required this.accentSecondary,
    required this.particle,
    required this.labelBackground,
    required this.labelText,
    required this.labelMuted,
    required this.stale,
    required this.palette,
    required this.additiveGlow,
  });

  /// Holographic dark — cyan light on deep navy, additive glow.
  const Radar3DTheme.dark()
      : backgroundCenter = const Color(0xFF0C1C33),
        backgroundEdge = const Color(0xFF02050B),
        discCenter = const Color(0xFF0F2B45),
        discEdge = const Color(0xFF07121F),
        grid = const Color(0xFF38BDF8),
        ring = const Color(0xFF67E8F9),
        accent = const Color(0xFF22D3EE),
        accentSecondary = const Color(0xFFA78BFA),
        particle = const Color(0xFFBAE6FD),
        labelBackground = const Color(0xE60A1322),
        labelText = const Color(0xFFF1F5F9),
        labelMuted = const Color(0xFF9FB3C8),
        stale = const Color(0xFF64748B),
        palette = const [
          Color(0xFF22D3EE),
          Color(0xFFA78BFA),
          Color(0xFFF472B6),
          Color(0xFFFBBF24),
          Color(0xFF34D399),
          Color(0xFF60A5FA),
        ],
        additiveGlow = true;

  /// Light — ink-blue lines on frosted white, normal blending.
  const Radar3DTheme.light()
      : backgroundCenter = const Color(0xFFFFFFFF),
        backgroundEdge = const Color(0xFFDCE6F2),
        discCenter = const Color(0xFFF4F8FD),
        discEdge = const Color(0xFFE3ECF7),
        grid = const Color(0xFF1D4ED8),
        ring = const Color(0xFF2563EB),
        accent = const Color(0xFF0284C7),
        accentSecondary = const Color(0xFF7C3AED),
        particle = const Color(0xFF3B82F6),
        labelBackground = const Color(0xF2FFFFFF),
        labelText = const Color(0xFF0F172A),
        labelMuted = const Color(0xFF475569),
        stale = const Color(0xFF94A3B8),
        palette = const [
          Color(0xFF0284C7),
          Color(0xFF7C3AED),
          Color(0xFFDB2777),
          Color(0xFFD97706),
          Color(0xFF059669),
          Color(0xFF2563EB),
        ],
        additiveGlow = false;

  final Color backgroundCenter;
  final Color backgroundEdge;
  final Color discCenter;
  final Color discEdge;
  final Color grid;
  final Color ring;
  final Color accent;
  final Color accentSecondary;
  final Color particle;
  final Color labelBackground;
  final Color labelText;
  final Color labelMuted;
  final Color stale;

  /// Per-device colors, picked by a stable hash of the device id.
  final List<Color> palette;

  /// Additive (light-emitting) blending for beams and glows; looks right on
  /// dark backgrounds only.
  final bool additiveGlow;
}
