/// `Radar3DView` — a holographic, perspective 3D radar.
///
/// * Tilted disc with range rings, bezel ticks and counter-rotating arcs.
/// * Volumetric sweep: a gradient trail plus a light curtain on the leading
///   edge; every target pings (orb flash + ground ripple) as it is swept.
/// * Targets are light pillars topped by glowing orbs, depth-sorted,
///   with billboard labels. Distance-only targets ride their range ring
///   (direction unknown); trilaterated targets sit at their fix with a
///   confidence ellipse on the floor.
/// * Drag to orbit (with inertia), double-tap to reset, tap a target to
///   select it. Idles into a slow auto-orbit.
/// * Respects reduced motion (`MediaQuery.disableAnimations`): the scene is
///   drawn static and only repaints on data or gestures.
///
/// Animation runs on a bare [Ticker] bound to the painter's repaint
/// Listenable — no widget rebuilds per frame.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'radar3d_painter.dart';
import 'radar3d_theme.dart';
import 'radar_target.dart';

class Radar3DView extends StatefulWidget {
  const Radar3DView({
    super.key,
    required this.targets,
    this.selectedId,
    this.onTargetTap,
    this.theme = const Radar3DTheme.dark(),
    this.interactive = true,
    this.autoOrbit = true,
    this.showLabels = true,
    this.rangeMeters,
    this.sweepPeriod = const Duration(milliseconds: 3200),
    this.initialPitchDegrees = 58,
    this.semanticLabel,
    this.initialTime,
    this.paintBackground = true,
  });

  /// What to draw (see [RadarTarget.fromStates]).
  final List<RadarTarget> targets;

  /// Highlighted target (bigger orb, spinning ring, always labelled).
  final String? selectedId;

  /// Called with the id of a tapped target.
  final ValueChanged<String>? onTargetTap;

  final Radar3DTheme theme;

  /// Drag-to-orbit / double-tap reset / tap-to-select.
  final bool interactive;

  /// Slow orbit after a few idle seconds.
  final bool autoOrbit;

  final bool showLabels;

  /// Fixed range (m); null = adaptive (eased "nice" range around targets).
  final double? rangeMeters;

  /// Time for one full sweep revolution.
  final Duration sweepPeriod;

  /// Initial camera elevation (20–89°).
  final double initialPitchDegrees;

  /// Overrides the generated accessibility summary.
  final String? semanticLabel;

  /// Starts the scene clock at this time (seconds) — handy for screenshots
  /// and golden tests that want a specific moment of the animation.
  final double? initialTime;

  /// Paint the theme's gradient backdrop. Set false to let the radar float
  /// on your own background.
  final bool paintBackground;

  @override
  State<Radar3DView> createState() => _Radar3DViewState();
}

class _Radar3DViewState extends State<Radar3DView> with SingleTickerProviderStateMixin {
  late final Radar3DController _c = Radar3DController(
    theme: widget.theme,
    pitch: widget.initialPitchDegrees.clamp(20, 89) * math.pi / 180,
    sweepPeriodSeconds: math.max(widget.sweepPeriod.inMilliseconds, 400) / 1000,
  );
  late final Radar3DPainter _painter = Radar3DPainter(_c);
  late final Ticker _ticker = createTicker(_onTick);
  Duration _last = Duration.zero;
  bool _reduceMotion = false;

  /// Tappable regions from the last paint (for tests).
  @visibleForTesting
  List<Radar3DHit> get debugHits => List.unmodifiable(_c.hits);

  @override
  void initState() {
    super.initState();
    _sync();
    final t0 = widget.initialTime;
    if (t0 != null && t0 > 0) {
      // Fast-forward in small steps so pings/orbit/range settle naturally.
      var left = t0;
      while (left > 0) {
        final dt = math.min(left, 1 / 30);
        _c.advance(dt);
        left -= dt;
      }
    }
    _c.range = _c.targetRange;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_reduceMotion) {
      if (_ticker.isActive) _ticker.stop();
      _c.advance(0, animate: false);
    } else if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  @override
  void didUpdateWidget(Radar3DView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
    if (_reduceMotion) _c.advance(0, animate: false);
  }

  void _sync() {
    _c
      ..targets = widget.targets
      ..selectedId = widget.selectedId
      ..theme = widget.theme
      ..showLabels = widget.showLabels
      ..autoOrbit = widget.autoOrbit
      ..fixedRange = widget.rangeMeters
      ..paintBackground = widget.paintBackground
      ..sweepPeriodSeconds = math.max(widget.sweepPeriod.inMilliseconds, 400) / 1000;
  }

  void _onTick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = elapsed;
    if (dt > 0) _c.advance(dt);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _c.dispose();
    super.dispose();
  }

  String _summary() {
    if (widget.semanticLabel != null) return widget.semanticLabel!;
    final live = widget.targets.where((t) => !t.stale).toList()..sort((a, b) => a.meters.compareTo(b.meters));
    if (widget.targets.isEmpty) return 'Radar. Scanning, no devices yet.';
    final n = widget.targets.length;
    final nearest = live.isEmpty ? null : live.first;
    final tail = nearest == null
        ? 'All signals lost.'
        : 'Nearest: ${nearest.label}, ${nearest.meters.toStringAsFixed(1)} meters.';
    return 'Radar. $n device${n == 1 ? '' : 's'}. $tail';
  }

  void _onTapUp(TapUpDetails d) {
    final cb = widget.onTargetTap;
    if (cb == null) return;
    String? best;
    var bestScore = double.infinity;
    for (final h in _c.hits) {
      final dist = (h.center - d.localPosition).distance;
      if (dist <= h.radius) {
        final score = dist + h.depth * 4; // prefer nearer targets on overlap
        if (score < bestScore) {
          bestScore = score;
          best = h.id;
        }
      }
    }
    if (best != null) cb(best);
  }

  @override
  Widget build(BuildContext context) {
    // Labels use the host app's font. The theme's body font is always set and
    // platform-correct (Roboto, San Francisco, Segoe…); the ambient style is
    // only a debug "monospace" when there's no Material ancestor.
    final themed = Theme.of(context).textTheme.bodyMedium;
    final ambient = DefaultTextStyle.of(context).style;
    _c.baseTextStyle = TextStyle(
      fontFamily: themed?.fontFamily ?? ambient.fontFamily,
      fontFamilyFallback: themed?.fontFamilyFallback ?? ambient.fontFamilyFallback,
    );
    Widget paint = CustomPaint(painter: _painter, child: const SizedBox.expand());
    if (widget.interactive) {
      paint = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) {
          _c.orbitBy(d.delta.dx, d.delta.dy);
          if (_reduceMotion) _c.advance(0, animate: false);
        },
        onPanEnd: (d) => _reduceMotion ? null : _c.release(d.velocity.pixelsPerSecond.dx),
        onDoubleTap: () {
          _c.resetView();
          if (_reduceMotion) {
            // No animation: jump straight to the default view.
            _c.orbitBy(0, 0);
          }
        },
        onTapUp: _onTapUp,
        child: paint,
      );
    }
    return Semantics(
      label: _summary(),
      container: true,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.hasBoundedWidth ? box.maxWidth : 340.0;
          final h = box.hasBoundedHeight ? box.maxHeight : w * 0.9;
          return SizedBox(width: w, height: h, child: RepaintBoundary(child: paint));
        },
      ),
    );
  }
}
