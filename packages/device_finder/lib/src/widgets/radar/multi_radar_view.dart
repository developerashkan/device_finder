import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../engine/tracker.dart';
import '../../engine/model.dart';
import '../listenable_adapter.dart';
import 'radar_scene.dart';
import 'radar_theme.dart';

class MultiRadarView extends StatefulWidget {
  const MultiRadarView({
    super.key,
    required this.tracker,
    this.size,
    this.theme = const RadarTheme.dark(),
  });

  final DeviceTracker tracker;
  final Size? size;
  final RadarTheme theme;

  @override
  State<MultiRadarView> createState() => _MultiRadarViewState();
}

class _MultiRadarViewState extends State<MultiRadarView> with SingleTickerProviderStateMixin {
  late final RadarScene _scene = RadarScene();
  Ticker? _ticker;
  Duration _lastElapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    final dt = elapsed - _lastElapsed;
    _lastElapsed = elapsed;
    final dtSeconds = (dt.inMicroseconds / 1e6).clamp(0.0, 0.1);
    if (dtSeconds <= 0) return;
    _scene.advance(dtSeconds);
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _scene.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.tracker.stateNotifier.toFlutter,
      builder: (context, _) {
        return CustomPaint(
          painter: MultiRadarPainter(
            _scene,
            widget.tracker.states.toList(),
            theme: widget.theme,
          ),
          size: widget.size ?? const Size(280, 280),
        );
      },
    );
  }
}

class MultiRadarPainter extends CustomPainter {
  MultiRadarPainter(this.scene, this.states, {RadarTheme theme = const RadarTheme.dark()})
      : _theme = theme,
        super(repaint: scene);

  final RadarScene scene;
  final List<TrackedDeviceState> states;
  final RadarTheme _theme;

  final Paint _bgPaint = Paint()..style = PaintingStyle.fill;
  final Paint _sectorPaint = Paint()..style = PaintingStyle.fill;
  final Paint _beamLeadPaint = Paint();
  final Paint _beamTrailPaint = Paint();
  final Paint _badgeFill = Paint()..style = PaintingStyle.fill;
  final Paint _ringPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.0;
  final Paint _spikePaint = Paint()..style = PaintingStyle.stroke;

  @override
  bool shouldRepaint(MultiRadarPainter oldDelegate) => false;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final minDim = size.shortestSide;
    final pxPerMeter = minDim / 24.0;

    // 0. Solid background.
    _bgPaint.color = _theme.background;
    canvas.drawCircle(c, radius, _bgPaint);

    // 0.1 Sci-fi ring.
    _drawSolomonRing(canvas, c, radius);

    // 1. Directional labels.
    _drawDirectionalLabels(canvas, c, radius);

    final sweep = scene.phase / 100.0;
    final b = scene.brightness;
    for (var i = 0; i < scene.sectors; i++) {
      final v = b[i];
      if (v <= 0.004) continue;
      final start = (i * 360 / scene.sectors) * math.pi / 180;
      final end = ((i + 1) * 360 / scene.sectors) * math.pi / 180;
      _sectorPaint.color = _theme.beam.withValues(alpha: 0.10 * v);
      canvas.drawArc(Rect.fromCircle(center: c, radius: radius), start, end - start, true, _sectorPaint);
    }

    final beamAngle = sweep * math.pi / 180;
    final beamRect = Rect.fromCircle(center: c, radius: radius);
    _beamLeadPaint.color = _theme.beam;
    canvas.drawArc(beamRect, beamAngle - 0.03, 0.06, true, _beamLeadPaint);
    _beamTrailPaint.color = _theme.beamFaint;
    canvas.drawArc(beamRect, beamAngle - 0.45, 0.42, true, _beamTrailPaint);

    for (final s in states) {
      if (!s.hasSignal) continue;
      final est = s.estimate;
      final fix = s.fix;
      if (est == null) continue;

      // Spreading logic for distance-only mode (fix == null).
      // Use device ID hash to get a unique stable "virtual bearing".
      final Offset rawCenter;
      if (fix != null) {
        rawCenter = c + Offset(fix.x * pxPerMeter, -fix.y * pxPerMeter);
      } else {
        final hash = s.info.id.hashCode.abs();
        // Spread around the top 120 degree arc (-60 to +60 from UP).
        final virtualBearingDeg = -60.0 + (hash % 120);
        final rad = (virtualBearingDeg - 90) * math.pi / 180;
        rawCenter = c + Offset(math.cos(rad), math.sin(rad)) * (est.meters * pxPerMeter);
      }

      final toCenter = rawCenter - c;
      final distFromCenter = toCenter.distance;
      final rim = radius - 14;
      final blipCenter = distFromCenter > rim ? c + toCenter * (rim / distFromCenter) : rawCenter;

      _badgeFill.color = est.isStale ? _theme.stale : _theme.badgeFill;
      canvas.drawCircle(blipCenter, 6, _badgeFill);
      
      // Trend.
      _drawTrendIndicator(canvas, blipCenter, s.trend);
      
      // Distance label.
      final distText = '${est.meters.toStringAsFixed(1)}m';
      final tpDist = TextPainter(
        text: TextSpan(
          text: distText,
          style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.white70),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tpDist.paint(canvas, blipCenter + const Offset(8, -4));
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
          style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: _theme.beam.withValues(alpha: 0.4), letterSpacing: 1.0),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final pos = c + Offset(dir.dx * (radius - 16), dir.dy * (radius - 16)) - Offset(tp.width / 2, tp.height / 2);
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
      path.moveTo(center.dx, center.dy - 10);
      path.lineTo(center.dx - 3, center.dy - 7);
      path.lineTo(center.dx + 3, center.dy - 7);
    } else {
      path.moveTo(center.dx, center.dy + 10);
      path.lineTo(center.dx - 3, center.dy + 7);
      path.lineTo(center.dx + 3, center.dy + 7);
    }
    path.close();
    canvas.drawPath(path, paint);
  }
}
