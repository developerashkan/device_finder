/// Design tokens — the flagship dark aesthetic for `device_finder`.
///
/// Palette, type, radii, spacing, and motion are centralized here so every
/// widget shares one source of truth. Numbers use tabular figures for stable
/// readouts.
library;

import 'package:flutter/material.dart';

abstract final class DfColors {
  static const background = Color(0xFF0A0E14);
  static const surface = Color(0xFF111826);
  static const surfaceHigh = Color(0xFF1A2333);

  static const accent = Color(0xFF22D3EE); // cyan — signal
  static const secondary = Color(0xFF818CF8); // indigo
  static const warning = Color(0xFFFBBF24);
  static const danger = Color(0xFFF87171);
  static const ok = Color(0xFF34D399);

  static const textPrimary = Color(0xFFF8FAFC);
  static const textSecondary = Color(0xFF94A3B8);
  static const textMuted = Color(0xFF8494AA); // ≥ 4.5:1 on background

  static const grid = Color(0x1FFFFFFF);
  static const ring = Color(0x33FFFFFF);

  static const Color accentFaint = Color(0x2222D3EE);
  static const Color accentMid = Color(0x6622D3EE);
}

abstract final class DfType {
  static const display = TextStyle(
    fontSize: 44,
    height: 1.05,
    fontWeight: FontWeight.w700,
    letterSpacing: -1.2,
    color: DfColors.textPrimary,
  );

  static const headline = TextStyle(
    fontSize: 26,
    height: 1.15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.4,
    color: DfColors.textPrimary,
  );

  static const title = TextStyle(
    fontSize: 17,
    height: 1.2,
    fontWeight: FontWeight.w600,
    color: DfColors.textPrimary,
  );

  static const body = TextStyle(
    fontSize: 14,
    height: 1.4,
    fontWeight: FontWeight.w400,
    color: DfColors.textSecondary,
  );

  static const label = TextStyle(
    fontSize: 12,
    height: 1.3,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.3,
    color: DfColors.textMuted,
  );

  /// Big readouts (distance, RSSI) — tabular figures, medium weight.
  static const value = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    fontFeatures: [FontFeature.tabularFigures()],
    color: DfColors.textPrimary,
  );

  static const valueSmall = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    fontFeatures: [FontFeature.tabularFigures()],
    color: DfColors.textSecondary,
  );
}

abstract final class DfRadius {
  static const small = 8.0;
  static const medium = 12.0;
  static const large = 16.0;
  static const xl = 24.0;
}

abstract final class DfSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

abstract final class DfMotion {
  /// Entrances — quick and snappy.
  static const quick = Duration(milliseconds: 200);
  static const quickCurve = Curves.easeOutCubic;

  /// Transitions — deliberate.
  static const standard = Duration(milliseconds: 300);
  static const standardCurve = Curves.easeInOutCubic;

  /// The radar sweep is always linear.
  static const sweepCurve = Curves.linear;
}
