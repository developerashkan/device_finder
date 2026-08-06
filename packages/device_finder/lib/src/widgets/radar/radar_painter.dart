/// The radar painter — per-frame zero-allocation drawing.
///
/// Renders: lit sector arcs (swept-area trail), grid rings, range rings, the
/// sweeping beam (two-tone arc), the target blip, the 95% confidence ellipse,
/// a teardrop distance pin, and the device-icon badge. Repaints are driven
/// purely by the [RadarScene] Listenable — `shouldRepaint => false`; the
/// widget never rebuilds during animation.
library;

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../engine/model.dart';
import 'radar_scene.dart';
import 'radar_theme.dart';

class RadarPainter extends CustomPainter {
  RadarPainter(this.scene, this.estimate, this.fix, this.info, {RadarTheme theme = const RadarTheme.dark(), this.trend = ProximityTrend.unknown})
      : _theme = theme,
        super(repaint: scene);

  final RadarScene scene;
  final DistanceEstimate? estimate;
  final PositionFix? fix;
  final DeviceInfo info;
  final RadarTheme _theme;
  final ProximityTrend trend;

  // Reused paints (zero per-frame allocation).
  final Paint _bgPaint = Paint()..style = PaintingStyle.fill;
  final Paint _sectorPaint = Paint()..style = PaintingStyle.fill;
  final Paint _beamLeadPaint = Paint();
  final Paint _beamTrailPaint = Paint();
  final Paint _blipPaint = Paint();
  final Paint _badgeFill = Paint()..style = PaintingStyle.fill;
  final Paint _ringPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.0;
  final Paint _spikePaint = Paint()..style = PaintingStyle.stroke;

  @override
  bool shouldRepaint(RadarPainter oldDelegate) => false;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final minDim = size.shortestSide;
    final pxPerMeter = minDim / 24.0; // 24 m visible on the short side

    // 0. Solid circular background.
    _bgPaint.color = _theme.background;
    canvas.drawCircle(c, radius, _bgPaint);

    // 0.1 Sci-fi spiky ring (Solomon style).
    _drawSolomonRing(canvas, c, radius);

    // 1. Directional labels.
    _drawDirectionalLabels(canvas, c, radius);

    // 2. Lit sectors (swept-area trail).
    final b = scene.brightness;
    final sweep = scene.phase / 100.0;
    for (var i = 0; i < scene.sectors; i++) {
      final v = b[i];
      if (v <= 0.004) continue;
      final start = (i * 360 / scene.sectors) * math.pi / 180;
      final end = ((i + 1) * 360 / scene.sectors) * math.pi / 180;
      if (i == sweep.floor() % scene.sectors) continue;
      _sectorPaint.color = _theme.beam.withValues(alpha: 0.10 * v);
      canvas.drawArc(Rect.fromCircle(center: c, radius: radius), start, end - start, true, _sectorPaint);
    }

    // 4. Sweeping beam.
    final beamAngle = sweep * math.pi / 180;
    final beamRect = Rect.fromCircle(center: c, radius: radius);
    _beamLeadPaint.color = _theme.beam;
    canvas.drawArc(beamRect, beamAngle - 0.03, 0.06, true, _beamLeadPaint);
    _beamTrailPaint.color = _theme.beamFaint;
    canvas.drawArc(beamRect, beamAngle - 0.45, 0.42, true, _beamTrailPaint);

    // 4.5 Center compass needle.
    final needlePaint = Paint()..color = Colors.white;
    final bearing = fix != null
        ? math.atan2(fix!.x, fix!.y)
        : (estimate != null ? 0.0 : 0.0);
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(bearing);
    final needle = Path()
      ..moveTo(0, -26)
      ..quadraticBezierTo(9, -8, 8, -4)
      ..lineTo(4, 10)
      ..lineTo(0, 6)
      ..lineTo(-4, 10)
      ..lineTo(-8, -4)
      ..quadraticBezierTo(-9, -8, 0, -26)
      ..close();
    canvas.drawPath(needle, needlePaint);
    canvas.restore();

    // 5. Blip + badge + pin + distance.
    final stale = estimate?.isStale ?? true;
    final rawCenter = fix != null
        ? c + Offset(fix!.x * pxPerMeter, -fix!.y * pxPerMeter)
        : (estimate != null ? c + Offset(0, -estimate!.meters * pxPerMeter) : null);
    if (rawCenter == null) return;

    final toCenter = rawCenter - c;
    final distFromCenter = toCenter.distance;
    final rim = radius - 26;
    final clamped = distFromCenter > rim;
    final blipCenter = clamped ? c + toCenter * (rim / distFromCenter) : rawCenter;

    {
      // Badge.
      _badgeFill.color = stale ? _theme.stale : _theme.badgeFill;
      canvas.drawCircle(blipCenter, 8, _badgeFill);
      final icon = info.kind == 'beacon'
          ? Icons.radar
          : info.kind == 'headphones'
              ? Icons.headphones
              : Icons.bluetooth;
      final tp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(fontSize: 9, fontFamily: icon.fontFamily, color: _theme.badgeIcon),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, blipCenter - Offset(tp.width / 2, tp.height / 2));

      // Trend.
      _drawTrendIndicator(canvas, blipCenter, trend);

      // Distance.
      if (estimate != null) {
        final distText = '${estimate!.meters.toStringAsFixed(1)}m';
        final tpDist = TextPainter(
          text: TextSpan(
            text: distText,
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white70),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tpDist.paint(canvas, blipCenter + const Offset(12, -5));
      }

      // Out-of-range arrow.
      if (clamped && distFromCenter > 1e-6) {
        final dir = toCenter / distFromCenter;
        final tip = blipCenter + dir * 16;
        final perp = Offset(-dir.dy, dir.dx);
        final arrow = Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(tip.dx - dir.dx * 8 + perp.dx * 4, tip.dy - dir.dy * 8 + perp.dy * 4)
          ..lineTo(tip.dx - dir.dx * 8 - perp.dx * 4, tip.dy - dir.dy * 8 - perp.dy * 4)
          ..close();
        _blipPaint
          ..color = _theme.beam
          ..style = PaintingStyle.fill;
        canvas.drawPath(arrow, _blipPaint);
      }
    }
  }

  void _drawSolomonRing(Canvas canvas, Offset c, double radius) {
    final ringRadius = radius - 4;
    _ringPaint.color = _theme.beam.withValues(alpha: 0.5);
    _ringPaint.strokeWidth = 3.0;
    canvas.drawCircle(c, ringRadius, _ringPaint);

    final path = Path();
    const int spikes = 144;
    for (var i = 0; i < spikes; i++) {
      final angle = (i * 360 / spikes) * math.pi / 180;
      final noise = math.sin(angle * 12 + scene.phase / 40.0) * 3.0 + 
                    math.cos(angle * 6 - scene.phase / 25.0) * 4.0;
      final h = 4.0 + noise.abs();
      
      final p1 = c + Offset(math.cos(angle), math.sin(angle)) * ringRadius;
      final p2 = c + Offset(math.cos(angle), math.sin(angle)) * (ringRadius + h);
      
      path.moveTo(p1.dx, p1.dy);
      path.lineTo(p2.dx, p2.dy);
    }
    _spikePaint.color = _theme.beam.withValues(alpha: 0.8);
    _spikePaint.strokeWidth = 1.5;
    canvas.drawPath(path, _spikePaint);
  }

  void _drawDirectionalLabels(Canvas canvas, Offset c, double radius) {
    const labels = [('UP', Offset(0, -1)), ('DOWN', Offset(0, 1)), ('LEFT', Offset(-1, 0)), ('RIGHT', Offset(1, 0))];
    for (final (text, dir) in labels) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: _theme.beam.withValues(alpha: 0.4), letterSpacing: 1.2),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final pos = c + Offset(dir.dx * (radius - 20), dir.dy * (radius - 20)) - Offset(tp.width / 2, tp.height / 2);
      tp.paint(canvas, pos);
    }
  }

  void _drawTrendIndicator(Canvas canvas, Offset center, ProximityTrend trend) {
    if (trend == ProximityTrend.unknown || trend == ProximityTrend.stable) return;
    final closing = trend == ProximityTrend.closing;
    final color = closing ? Colors.greenAccent : Colors.redAccent;
    final paint = Paint()..color = color..style = PaintingStyle.fill;
    final path = Path();
    if (closing) {
      path.moveTo(center.dx, center.dy - 14);
      path.lineTo(center.dx - 4, center.dy - 10);
      path.lineTo(center.dx + 4, center.dy - 10);
    } else {
      path.moveTo(center.dx, center.dy + 14);
      path.lineTo(center.dx - 4, center.dy + 10);
      path.lineTo(center.dx + 4, center.dy + 10);
    }
    path.close();
    canvas.drawPath(path, paint);
  }
}
