/// 95% confidence ellipse map — the tracked position, its uncertainty
/// ellipse, and observer anchors, drawn on a grid.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design/design.dart';
import '../../engine/model.dart';

class EllipseMap extends StatelessWidget {
  const EllipseMap({super.key, this.fix, this.estimate, this.anchors, this.repaint});

  final PositionFix? fix;
  final DistanceEstimate? estimate;
  final List<Offset>? anchors;
  final Listenable? repaint;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _EllipsePainter(fix, estimate, anchors, repaint),
      size: const Size(240, 240),
    );
  }
}

class _EllipsePainter extends CustomPainter {
  _EllipsePainter(this.fix, this.estimate, this.anchors, this.repaint) : super(repaint: repaint);

  final PositionFix? fix;
  final DistanceEstimate? estimate;
  final List<Offset>? anchors;
  final Listenable? repaint;

  final Paint _gridPaint = Paint()
    ..color = DfColors.grid
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;
  final Paint _ellipsePaint = Paint()
    ..color = DfColors.accentFaint
    ..style = PaintingStyle.fill;
  final Paint _ellipseStroke = Paint()
    ..color = DfColors.accent.withValues(alpha: 0.7)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;
  final Paint _anchorPaint = Paint()..color = DfColors.secondary;
  final Paint _blipPaint = Paint()..color = DfColors.accent;

  @override
  bool shouldRepaint(_EllipsePainter oldDelegate) => false;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final pxPerMeter = size.shortestSide / 12.0;

    // Grid.
    for (var i = 1; i <= 3; i++) {
      canvas.drawCircle(c, size.shortestSide * i / 6, _gridPaint);
    }
    canvas.drawLine(Offset(c.dx - size.width / 2, c.dy), Offset(c.dx + size.width / 2, c.dy), _gridPaint);
    canvas.drawLine(Offset(c.dx, c.dy - size.height / 2), Offset(c.dx, c.dy + size.height / 2), _gridPaint);

    // Anchors.
    for (final a in anchors ?? const <Offset>[]) {
      final p = c + Offset(a.dx * pxPerMeter, -a.dy * pxPerMeter);
      canvas.drawCircle(p, 4, _anchorPaint);
      canvas.drawCircle(p, 7, Paint()
        ..color = DfColors.secondary.withValues(alpha: 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1);
    }

    final blip = fix != null
        ? c + Offset(fix!.x * pxPerMeter, -fix!.y * pxPerMeter)
        : (estimate != null ? c + Offset(0, -estimate!.meters * pxPerMeter) : null);
    if (blip == null) return;

    // Confidence ellipse.
    if (fix != null) {
      final (major, minor, thetaDeg) = fix!.confidenceEllipse();
      canvas.save();
      canvas.translate(blip.dx, blip.dy);
      canvas.rotate(thetaDeg * math.pi / 180);
      canvas.scale(major * pxPerMeter, minor * pxPerMeter);
      canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: 2, height: 2), _ellipsePaint);
      canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: 2, height: 2), _ellipseStroke);
      canvas.restore();
    }

    canvas.drawCircle(blip, 5, _blipPaint);
  }
}
