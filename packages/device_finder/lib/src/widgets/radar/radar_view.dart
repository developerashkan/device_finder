/// The premium sweeping radar widget.
///
/// Hosts the shared [RadarScene], runs the bare `Ticker` animation loop, and
/// paints via [RadarPainter] (bound to the scene — zero widget rebuilds).
/// Live BLE data flows in through [estimate]/[fix]/[info] — the widget's
/// `didUpdateWidget` just updates the painter's field pointers.
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../engine/model.dart';
import 'radar_painter.dart';
import 'radar_scene.dart';
import 'radar_theme.dart';

class RadarView extends StatefulWidget {
  const RadarView({
    super.key,
    this.estimate,
    this.fix,
    this.info,
    this.trend = ProximityTrend.unknown,
    this.size,
    this.theme = const RadarTheme.dark(),
  });

  final DistanceEstimate? estimate;
  final PositionFix? fix;
  final DeviceInfo? info;
  final ProximityTrend trend;

  /// Square or rectangular; defaults to a large square.
  final Size? size;

  /// Radar color theme (light / dark).
  final RadarTheme theme;

  @override
  State<RadarView> createState() => _RadarViewState();
}

class _RadarViewState extends State<RadarView> with SingleTickerProviderStateMixin {
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
    // dt in seconds; clamp to avoid a giant jump after an app pause.
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
    return CustomPaint(
      painter: RadarPainter(
        _scene,
        widget.estimate,
        widget.fix,
        widget.info ?? DeviceInfo(id: ''),
        theme: widget.theme,
        trend: widget.trend,
      ),
      size: widget.size ?? const Size(280, 280),
    );
  }
}
