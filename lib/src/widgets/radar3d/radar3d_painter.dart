/// Scene state + painter for [Radar3DView].
///
/// The controller owns everything that animates (time, sweep, camera,
/// pings, adaptive range). The painter is bound to it as its repaint
/// Listenable, so animation never rebuilds widgets. All geometry is
/// projected through [Radar3DCamera]; drawing is ordered back-to-front.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../engine/model.dart';
import 'radar3d_camera.dart';
import 'radar3d_theme.dart';
import 'radar_target.dart';

/// A tappable target region in screen space (from the last paint).
class Radar3DHit {
  const Radar3DHit(this.id, this.center, this.radius, this.depth);
  final String id;
  final Offset center;
  final double radius;
  final double depth;
}

class Radar3DController extends ChangeNotifier {
  Radar3DController({
    required this.theme,
    double pitch = 58 * math.pi / 180,
    this.sweepPeriodSeconds = 3.2,
  })  : defaultPitch = pitch,
        _pitch = pitch;

  Radar3DTheme theme;
  double sweepPeriodSeconds;
  final double defaultPitch;

  List<RadarTarget> targets = const [];
  String? selectedId;
  bool showLabels = true;
  bool autoOrbit = true;

  /// When false the scene is drawn on a transparent canvas (blends into the
  /// host app's own background).
  bool paintBackground = true;

  /// Ambient text style (font family etc.) so labels match the host app.
  TextStyle baseTextStyle = const TextStyle();
  double? fixedRange;

  /// Seconds since start (drives particles, pulses, orbiting markers).
  double time = 0;

  /// Sweep angle (radians, clockwise from forward).
  double sweep = 0.6;

  double _yaw = -0.35;
  double _pitch;
  double get yaw => _yaw;
  double get pitch => _pitch;

  double _yawVelocity = 0;
  double _idleSeconds = 10;
  bool _resetting = false;

  /// Displayed range (m), eased toward the adaptive target range.
  double range = 8;

  /// Last time (in [time]) the sweep crossed each target.
  final Map<String, double> pings = {};

  /// Hit regions written by the painter.
  final List<Radar3DHit> hits = [];

  static const List<double> _niceRanges = [2, 3, 4, 6, 8, 10, 12, 16, 20, 25, 30];

  double get targetRange {
    if (fixedRange != null) return fixedRange!;
    var far = 0.0;
    for (final t in targets) {
      final m = t.radialMeters;
      if (m.isFinite) far = math.max(far, m);
    }
    final want = far * 1.25;
    for (final r in _niceRanges) {
      if (r >= want) return r;
    }
    return _niceRanges.last;
  }

  /// User drag: [dx]/[dy] in logical pixels.
  void orbitBy(double dx, double dy) {
    _resetting = false;
    _idleSeconds = 0;
    _yaw += dx * 0.0085;
    _pitch = (_pitch - dy * 0.0065).clamp(Radar3DCamera.minPitch, Radar3DCamera.maxPitch);
    notifyListeners();
  }

  void release(double velocityX) {
    _yawVelocity = (velocityX * 0.0085).clamp(-6.0, 6.0);
    _idleSeconds = 0;
  }

  /// Animates the camera back to its default angle.
  void resetView() {
    _resetting = true;
    _yawVelocity = 0;
    notifyListeners();
  }

  /// Advances one frame. With [animate] false (reduced motion) only the
  /// state needed for a correct static picture is updated.
  void advance(double dt, {bool animate = true}) {
    if (!animate) {
      range = targetRange;
      notifyListeners();
      return;
    }
    final prevSweep = sweep;
    time += dt;
    sweep = (sweep + 2 * math.pi * dt / sweepPeriodSeconds) % (2 * math.pi);

    // Pings: the sweep crossed a target's bearing during this frame.
    final swept = (sweep - prevSweep) % (2 * math.pi);
    for (final t in targets) {
      if (t.stale) continue;
      final b = t.bearingAt(time);
      final delta = (b - prevSweep) % (2 * math.pi);
      if (delta <= swept) pings[t.id] = time;
    }
    if (pings.length > targets.length + 8) {
      final live = {for (final t in targets) t.id};
      pings.removeWhere((k, _) => !live.contains(k));
    }

    // Camera: inertia, auto-orbit when idle, animated reset.
    _idleSeconds += dt;
    if (_resetting) {
      final k = 1 - math.exp(-dt * 6);
      final targetYaw = -0.35;
      var dyaw = (targetYaw - _yaw) % (2 * math.pi);
      if (dyaw > math.pi) dyaw -= 2 * math.pi;
      _yaw += dyaw * k;
      _pitch += (defaultPitch - _pitch) * k;
      if (dyaw.abs() < 1e-3 && (defaultPitch - _pitch).abs() < 1e-3) _resetting = false;
    } else if (_yawVelocity.abs() > 1e-3) {
      _yaw += _yawVelocity * dt;
      _yawVelocity *= math.exp(-dt * 3.2);
    } else if (autoOrbit && _idleSeconds > 3) {
      _yaw += 0.05 * dt * math.min(1, (_idleSeconds - 3) / 2);
    }

    final k = 1 - math.exp(-dt * 2.5);
    range += (targetRange - range) * k;
    notifyListeners();
  }
}

class Radar3DPainter extends CustomPainter {
  Radar3DPainter(this.c) : super(repaint: c);

  final Radar3DController c;

  final Radar3DCamera _cam = Radar3DCamera();
  final Map<String, TextPainter> _text = {};

  // Fit cache.
  Size _fitSize = Size.zero;
  double _fitPitch = -1;
  double _scale = 1;
  Offset _origin = Offset.zero;

  // Reused paints.
  final Paint _fill = Paint()..isAntiAlias = true;
  final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..isAntiAlias = true;
  final Paint _glow = Paint()..isAntiAlias = true;
  final Paint _vertexPaint = Paint();

  static const int _segs = 120;
  static final Float64List _sin = Float64List.fromList(List.generate(_segs + 1, (i) => math.sin(i * 2 * math.pi / _segs)));
  static final Float64List _cos = Float64List.fromList(List.generate(_segs + 1, (i) => math.cos(i * 2 * math.pi / _segs)));

  // Deterministic particle field.
  static final List<(double, double, double, double, double)> _particles = () {
    var s = 0x2545F491;
    double rnd() {
      s = (RadarTarget.mul32(s, 1103515245) + 12345) & 0x7fffffff;
      return s / 0x7fffffff;
    }

    return List.generate(64, (_) => (math.sqrt(rnd()) * 1.25, rnd() * 2 * math.pi, rnd() * 0.9, 0.03 + rnd() * 0.06, 0.6 + rnd() * 1.2));
  }();

  @override
  bool shouldRepaint(Radar3DPainter oldDelegate) => oldDelegate.c != c;

  // ------------------------------------------------------------------ helpers

  ProjectedPoint _p(double x, double y, double z) => _cam.project(x, y, z);

  Offset _o(ProjectedPoint p) => Offset(_origin.dx + p.x * _scale, _origin.dy + p.y * _scale);

  Offset _ground(double r, double a, [double z = 0]) => _o(_p(r * math.sin(a), r * math.cos(a), z));

  Path _ringPath(double r, {double z = 0}) {
    final path = Path();
    for (var i = 0; i <= _segs; i++) {
      final pt = _o(_p(r * _sin[i], r * _cos[i], z));
      if (i == 0) {
        path.moveTo(pt.dx, pt.dy);
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }
    return path..close();
  }

  Path _arcPath(double r, double from, double to, {int steps = 40}) {
    final path = Path();
    for (var i = 0; i <= steps; i++) {
      final a = from + (to - from) * i / steps;
      final pt = _ground(r, a);
      if (i == 0) {
        path.moveTo(pt.dx, pt.dy);
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }
    return path;
  }

  void _fit(Size size) {
    if (size == _fitSize && (_fitPitch - _cam.pitch).abs() < 1e-6) return;
    _fitSize = size;
    _fitPitch = _cam.pitch;
    final (l, t, r, b) = _cam.discBounds();
    final w = r - l, h = b - t;
    _scale = math.min(size.width * 0.96 / w, size.height * 0.94 / h);
    final cx = (l + r) / 2, cy = (t + b) / 2;
    _origin = Offset(size.width / 2 - cx * _scale, size.height / 2 - cy * _scale);
  }

  TextPainter _label(String text, TextStyle styleIn) {
    final style = c.baseTextStyle.merge(styleIn);
    final key = '${style.hashCode}|$text';
    final cached = _text[key];
    if (cached != null) return cached;
    if (_text.length > 96) _text.clear();
    return _text[key] = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
  }

  Color _colorFor(RadarTarget t, Radar3DTheme th) =>
      t.stale ? th.stale : th.palette[t.stableHash % th.palette.length];

  static String _fmtMeters(double m) => m < 10 ? m.toStringAsFixed(1) : m.toStringAsFixed(0);

  // ------------------------------------------------------------------- paint

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final th = c.theme;
    _cam.set(c.yaw, c.pitch);
    _fit(size);
    c.hits.clear();

    final glowMode = th.additiveGlow ? BlendMode.plus : BlendMode.srcOver;

    if (c.paintBackground) _background(canvas, size, th);
    _floorGrid(canvas, th);
    _disc(canvas, th);
    _rangeBands(canvas, th);
    _rings(canvas, th);
    _bezel(canvas, th);
    _sweep(canvas, th, glowMode);
    _observer(canvas, th, glowMode);
    _particlesLayer(canvas, th, glowMode);
    _targets(canvas, th, glowMode);
  }

  void _background(Canvas canvas, Size size, Radar3DTheme th) {
    _fill
      ..blendMode = BlendMode.srcOver
      ..color = const Color(0xFFFFFFFF)
      ..shader = ui.Gradient.radial(
        _origin,
        size.longestSide * 0.85,
        [th.backgroundCenter, th.backgroundEdge],
      );
    canvas.drawRect(Offset.zero & size, _fill);
    _fill.shader = null;
  }

  void _floorGrid(Canvas canvas, Radar3DTheme th) {
    final path = Path();
    const ext = 1.9, step = 0.2375;
    for (var k = -8; k <= 8; k++) {
      final v = k * step;
      final a = _o(_p(v, -ext, 0)), b = _o(_p(v, ext, 0));
      final d = _o(_p(-ext, v, 0)), e = _o(_p(ext, v, 0));
      path
        ..moveTo(a.dx, a.dy)
        ..lineTo(b.dx, b.dy)
        ..moveTo(d.dx, d.dy)
        ..lineTo(e.dx, e.dy);
    }
    _stroke
      ..strokeWidth = 1
      ..blendMode = BlendMode.srcOver
      ..color = const Color(0xFFFFFFFF)
      ..shader = ui.Gradient.radial(
        _origin,
        _scale * 1.9,
        [th.grid.withValues(alpha: 0.16), th.grid.withValues(alpha: 0.05), th.grid.withValues(alpha: 0)],
        [0, 0.55, 1],
      );
    canvas.drawPath(path, _stroke);
    _stroke.shader = null;
  }

  void _disc(Canvas canvas, Radar3DTheme th) {
    final disc = _ringPath(1.0);
    _fill
      ..blendMode = BlendMode.srcOver
      ..color = const Color(0xFFFFFFFF)
      ..shader = ui.Gradient.radial(_origin, _scale * 1.05, [
        th.discCenter.withValues(alpha: 0.92),
        th.discEdge.withValues(alpha: 0.78),
      ]);
    canvas.drawPath(disc, _fill);
    _fill.shader = null;

    // Spokes every 30°.
    final spokes = Path();
    for (var i = 0; i < 12; i++) {
      final a = i * math.pi / 6;
      final p0 = _ground(0.08, a), p1 = _ground(1.0, a);
      spokes
        ..moveTo(p0.dx, p0.dy)
        ..lineTo(p1.dx, p1.dy);
    }
    _stroke
      ..strokeWidth = 1
      ..color = th.ring.withValues(alpha: 0.10);
    canvas.drawPath(spokes, _stroke);
  }

  void _rings(Canvas canvas, Radar3DTheme th) {
    final style = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: th.labelMuted,
      fontFeatures: const [ui.FontFeature.tabularFigures()],
      letterSpacing: 0.2,
    );
    for (var k = 1; k <= 4; k++) {
      final r = k / 4;
      _stroke
        ..strokeWidth = k == 4 ? 1.6 : 1
        ..color = th.ring.withValues(alpha: k == 4 ? 0.55 : 0.20);
      canvas.drawPath(_ringPath(r), _stroke);
      // Distance label on the near (camera-facing) side, slightly right.
      final a = math.pi * 0.82 + c.yaw;
      final pos = _ground(r, a);
      final tp = _label('${_fmtMeters(c.range * r)} m', style);
      final at = pos + Offset(4, -tp.height - 2);
      _fill
        ..blendMode = BlendMode.srcOver
        ..color = th.discEdge.withValues(alpha: 0.55);
      canvas.drawRRect(
        RRect.fromRectAndRadius((at - const Offset(4, 1)) & Size(tp.width + 8, tp.height + 2), const Radius.circular(6)),
        _fill,
      );
      tp.paint(canvas, at);
    }
  }

  void _bezel(Canvas canvas, Radar3DTheme th) {
    // Tick marks every 5°, longer every 30°.
    final ticks = Path();
    for (var i = 0; i < 72; i++) {
      final a = i * math.pi / 36;
      final major = i % 6 == 0;
      final p0 = _ground(1.035, a), p1 = _ground(major ? 1.1 : 1.07, a);
      ticks
        ..moveTo(p0.dx, p0.dy)
        ..lineTo(p1.dx, p1.dy);
    }
    _stroke
      ..strokeWidth = 1.2
      ..color = th.ring.withValues(alpha: 0.38);
    canvas.drawPath(ticks, _stroke);

    // Counter-rotating segment arcs — slow motion-graphics layer.
    final t = c.time;
    _stroke
      ..strokeWidth = 2
      ..color = th.accent.withValues(alpha: 0.55);
    for (var i = 0; i < 3; i++) {
      final s = t * 0.25 + i * 2 * math.pi / 3;
      canvas.drawPath(_arcPath(1.14, s, s + 0.9), _stroke);
    }
    _stroke
      ..strokeWidth = 1.2
      ..color = th.accentSecondary.withValues(alpha: 0.5);
    for (var i = 0; i < 4; i++) {
      final s = -t * 0.18 + i * math.pi / 2;
      canvas.drawPath(_arcPath(1.18, s, s + 0.45), _stroke);
    }

    // Forward marker.
    final tip = _ground(1.26, 0), l = _ground(1.2, -0.05), r = _ground(1.2, 0.05);
    _fill
      ..blendMode = BlendMode.srcOver
      ..color = th.accent.withValues(alpha: 0.9);
    canvas.drawPath(Path()..moveTo(tip.dx, tip.dy)..lineTo(l.dx, l.dy)..lineTo(r.dx, r.dy)..close(), _fill);
  }

  void _rangeBands(Canvas canvas, Radar3DTheme th) {
    // Distance-only targets live somewhere on a ring: draw that ring.
    for (final t in c.targets) {
      if (t.hasPosition) continue;
      final selected = t.id == c.selectedId;
      final col = _colorFor(t, th);
      final r = (t.meters / c.range).clamp(0.02, 1.0);
      final half = math.max(t.sigmaMeters / c.range, 0.012).clamp(0.012, 0.12);
      final band = Path()
        ..fillType = PathFillType.evenOdd
        ..addPath(_ringPath(math.min(r + half, 1.0)), Offset.zero)
        ..addPath(_ringPath(math.max(r - half, 0.0)), Offset.zero);
      _fill
        ..blendMode = BlendMode.srcOver
        ..color = col.withValues(alpha: selected ? 0.20 : 0.07);
      canvas.drawPath(band, _fill);
      _stroke
        ..strokeWidth = selected ? 1.6 : 1
        ..color = col.withValues(alpha: selected ? 0.75 : 0.28);
      canvas.drawPath(_ringPath(r), _stroke);
    }

    // Confidence ellipses for positioned targets.
    for (final t in c.targets) {
      if (!t.hasPosition) continue;
      final col = _colorFor(t, th);
      final r = math.max(t.sigmaMeters, 0.25) * 2.0 / c.range;
      final cx = t.x! / c.range, cy = t.y! / c.range;
      final path = Path();
      for (var i = 0; i <= 48; i++) {
        final a = i * 2 * math.pi / 48;
        final pt = _o(_p(cx + r * math.sin(a), cy + r * math.cos(a), 0));
        if (i == 0) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      path.close();
      _fill
        ..blendMode = BlendMode.srcOver
        ..color = col.withValues(alpha: 0.12);
      canvas.drawPath(path, _fill);
      _stroke
        ..strokeWidth = 1
        ..color = col.withValues(alpha: 0.45);
      canvas.drawPath(path, _stroke);
    }
  }

  void _sweep(Canvas canvas, Radar3DTheme th, BlendMode mode) {
    const n = 32;
    const span = 1.25; // radians of trail
    final a0 = c.sweep;
    final center = _o(_p(0, 0, 0));
    final positions = Float32List(n * 6);
    final colors = Int32List(n * 3);
    final base = th.accent;
    for (var i = 0; i < n; i++) {
      final f0 = i / n, f1 = (i + 1) / n;
      final p0 = _ground(1.0, a0 - span * (1 - f0));
      final p1 = _ground(1.0, a0 - span * (1 - f1));
      positions
        ..[i * 6] = center.dx
        ..[i * 6 + 1] = center.dy
        ..[i * 6 + 2] = p0.dx
        ..[i * 6 + 3] = p0.dy
        ..[i * 6 + 4] = p1.dx
        ..[i * 6 + 5] = p1.dy;
      colors
        ..[i * 3] = base.withValues(alpha: 0.02).toARGB32()
        ..[i * 3 + 1] = base.withValues(alpha: 0.42 * f0 * f0).toARGB32()
        ..[i * 3 + 2] = base.withValues(alpha: 0.42 * f1 * f1).toARGB32();
    }
    _vertexPaint.blendMode = mode;
    canvas.drawVertices(
      ui.Vertices.raw(ui.VertexMode.triangles, positions, colors: colors),
      BlendMode.dst,
      _vertexPaint,
    );

    // Volumetric light curtain on the leading edge.
    const m = 10;
    const height = 0.42;
    final cp = Float32List(m * 12);
    final cc = Int32List(m * 6);
    for (var j = 0; j < m; j++) {
      final r0 = 0.04 + 0.96 * j / m, r1 = 0.04 + 0.96 * (j + 1) / m;
      final b0 = _ground(r0, a0), b1 = _ground(r1, a0);
      final t0 = _ground(r0, a0, height * (0.35 + 0.65 * r0));
      final t1 = _ground(r1, a0, height * (0.35 + 0.65 * r1));
      final bottom0 = base.withValues(alpha: 0.46 * (0.35 + 0.65 * r0)).toARGB32();
      final bottom1 = base.withValues(alpha: 0.46 * (0.35 + 0.65 * r1)).toARGB32();
      final top = base.withValues(alpha: 0).toARGB32();
      final o = j * 12;
      cp
        ..[o] = b0.dx
        ..[o + 1] = b0.dy
        ..[o + 2] = b1.dx
        ..[o + 3] = b1.dy
        ..[o + 4] = t1.dx
        ..[o + 5] = t1.dy
        ..[o + 6] = b0.dx
        ..[o + 7] = b0.dy
        ..[o + 8] = t1.dx
        ..[o + 9] = t1.dy
        ..[o + 10] = t0.dx
        ..[o + 11] = t0.dy;
      final q = j * 6;
      cc
        ..[q] = bottom0
        ..[q + 1] = bottom1
        ..[q + 2] = top
        ..[q + 3] = bottom0
        ..[q + 4] = top
        ..[q + 5] = top;
    }
    canvas.drawVertices(ui.Vertices.raw(ui.VertexMode.triangles, cp, colors: cc), BlendMode.dst, _vertexPaint);

    // Bright leading edge.
    final rim = _ground(1.0, a0);
    _stroke
      ..strokeWidth = 2
      ..blendMode = mode
      ..color = base.withValues(alpha: 0.95);
    canvas.drawLine(center, rim, _stroke);
    _stroke.blendMode = BlendMode.srcOver;
  }

  void _observer(Canvas canvas, Radar3DTheme th, BlendMode mode) {
    // Expanding pulse.
    final phase = (c.time % 2.4) / 2.4;
    _stroke
      ..strokeWidth = 1.5
      ..color = th.accent.withValues(alpha: 0.6 * (1 - phase));
    canvas.drawPath(_ringPath(0.04 + 0.14 * phase), _stroke);

    // Heading cone (the user faces forward).
    final tip = _o(_p(0, 0.16, 0)), l = _o(_p(-0.05, 0.02, 0)), r = _o(_p(0.05, 0.02, 0)), back = _o(_p(0, 0.05, 0));
    _fill
      ..blendMode = BlendMode.srcOver
      ..color = th.accent.withValues(alpha: 0.85);
    canvas.drawPath(Path()..moveTo(tip.dx, tip.dy)..lineTo(r.dx, r.dy)..lineTo(back.dx, back.dy)..lineTo(l.dx, l.dy)..close(), _fill);

    final core = _o(_p(0, 0, 0));
    _glow
      ..blendMode = mode
      ..color = const Color(0xFFFFFFFF)
      ..shader = ui.Gradient.radial(core, 16, [th.accent.withValues(alpha: 0.8), th.accent.withValues(alpha: 0)]);
    canvas.drawCircle(core, 16, _glow);
    _glow.shader = null;
    _fill.color = th.labelText;
    canvas.drawCircle(core, 3.2, _fill);
  }

  void _particlesLayer(Canvas canvas, Radar3DTheme th, BlendMode mode) {
    _fill.blendMode = mode;
    final t = c.time;
    for (final (r, a, z0, speed, size) in _particles) {
      final z = (z0 + speed * t) % 0.9;
      final alpha = math.sin(math.pi * z / 0.9) * 0.5;
      final p = _p(r * math.sin(a + t * 0.02), r * math.cos(a + t * 0.02), z);
      _fill.color = th.particle.withValues(alpha: alpha * (th.additiveGlow ? 1 : 0.5));
      canvas.drawCircle(_o(p), size * p.scale, _fill);
    }
    _fill.blendMode = BlendMode.srcOver;
  }

  void _targets(Canvas canvas, Radar3DTheme th, BlendMode mode) {
    if (c.targets.isEmpty) return;
    final items = <(RadarTarget, double, double, bool, ProjectedPoint)>[];
    for (final t in c.targets) {
      final a = t.bearingAt(c.time);
      var r = t.radialMeters / c.range;
      final out = r > 1.0;
      if (out) r = 1.0;
      if (!r.isFinite) continue;
      final g = _p(r * math.sin(a), r * math.cos(a), 0);
      items.add((t, a, r, out, g));
    }
    items.sort((p, q) => q.$5.depth.compareTo(p.$5.depth)); // far → near

    // Label budget: selected + nearest live targets, scaled to the view so a
    // phone-sized radar never drowns in labels (the orbs always show).
    final budget = _fitSize.width < 520 ? 3 : 6;
    final nearest = [...c.targets.where((t) => !t.stale)]..sort((a, b) => a.meters.compareTo(b.meters));
    final labelled = <String>{
      if (c.selectedId != null) c.selectedId!,
      for (final t in nearest) t.id,
    }.take(budget).toSet();
    final labels = <(RadarTarget, Color, Offset, double, bool, double)>[];
    for (final (t, a, r, out, g) in items) {
      final selected = t.id == c.selectedId;
      final col = _colorFor(t, th);
      final ground = _o(g);
      final s = t.strength.clamp(0.0, 1.0);
      final height = 0.22 + 0.40 * s;
      final topP = _p(r * math.sin(a), r * math.cos(a), height);
      final top = _o(topP);
      final k = topP.scale;

      // Ground glow + ping ripple.
      _glow
        ..blendMode = mode
        ..color = const Color(0xFFFFFFFF)
      ..shader = ui.Gradient.radial(ground, 18 * k, [col.withValues(alpha: 0.45), col.withValues(alpha: 0)]);
      canvas.drawCircle(ground, 18 * k, _glow);
      _glow.shader = null;

      final ping = c.pings[t.id];
      if (ping != null) {
        final age = c.time - ping;
        if (age >= 0 && age < 1.6) {
          final f = age / 1.6;
          final rr = 0.02 + 0.13 * Curves.easeOutCubic.transform(f);
          final ripple = Path();
          for (var i = 0; i <= 40; i++) {
            final aa = i * 2 * math.pi / 40;
            final pt = _o(_p(r * math.sin(a) + rr * math.sin(aa), r * math.cos(a) + rr * math.cos(aa), 0));
            if (i == 0) {
              ripple.moveTo(pt.dx, pt.dy);
            } else {
              ripple.lineTo(pt.dx, pt.dy);
            }
          }
          _stroke
            ..strokeWidth = 1.6
            ..color = col.withValues(alpha: 0.8 * (1 - f));
          canvas.drawPath(ripple..close(), _stroke);
        }
      }

      // Pillar: a beam of light from the floor to the orb.
      _stroke
        ..strokeWidth = math.max(1.5, 2.4 * k)
        ..blendMode = mode
        ..color = const Color(0xFFFFFFFF)
      ..shader = ui.Gradient.linear(ground, top, [col.withValues(alpha: 0.05), col.withValues(alpha: t.stale ? 0.35 : 0.85)]);
      if (t.stale || !t.hasPosition) {
        // Dashed: stale, or direction unknown.
        const dashes = 7;
        for (var i = 0; i < dashes; i++) {
          final f0 = i / dashes, f1 = (i + 0.55) / dashes;
          canvas.drawLine(Offset.lerp(ground, top, f0)!, Offset.lerp(ground, top, f1)!, _stroke);
        }
      } else {
        canvas.drawLine(ground, top, _stroke);
      }
      _stroke
        ..shader = null
        ..blendMode = BlendMode.srcOver;

      // Orb: glow halo, flash on ping, bright core.
      final flash = ping == null ? 0.0 : math.max(0.0, 1 - (c.time - ping) / 0.6);
      final orbR = (8.0 + 5.0 * s) * k * (selected ? 1.2 : 1.0);
      _glow
        ..blendMode = mode
        ..color = const Color(0xFFFFFFFF)
      ..shader = ui.Gradient.radial(top, orbR * (3.2 + 1.5 * flash), [
          col.withValues(alpha: t.stale ? 0.25 : 0.55 + 0.35 * flash),
          col.withValues(alpha: 0),
        ]);
      canvas.drawCircle(top, orbR * (3.2 + 1.5 * flash), _glow);
      _glow.shader = null;
      _fill
        ..blendMode = BlendMode.srcOver
        ..color = const Color(0xFFFFFFFF)
      ..shader = ui.Gradient.radial(top - Offset(orbR * 0.3, orbR * 0.35), orbR * 1.2, [
          Color.lerp(Colors.white, col, 0.25)!,
          col,
          Color.lerp(col, Colors.black, 0.35)!,
        ], [
          0,
          0.55,
          1,
        ]);
      canvas.drawCircle(top, orbR, _fill);
      _fill.shader = null;

      if (selected) {
        _stroke
          ..strokeWidth = 1.6
          ..color = col.withValues(alpha: 0.9);
        final spin = c.time * 1.4;
        for (var i = 0; i < 3; i++) {
          final st = spin + i * 2 * math.pi / 3;
          canvas.drawArc(Rect.fromCircle(center: top, radius: orbR + 6), st, 1.4, false, _stroke);
        }
      }

      // Out of range: chevron pointing outward along the rim.
      if (out) {
        final o1 = _ground(1.08, a), o0 = _ground(1.02, a - 0.04), o2 = _ground(1.02, a + 0.04);
        _fill.color = col;
        canvas.drawPath(Path()..moveTo(o1.dx, o1.dy)..lineTo(o0.dx, o0.dy)..lineTo(o2.dx, o2.dy)..close(), _fill);
      }

      c.hits.add(Radar3DHit(t.id, top, math.max(orbR * 1.8, 24), topP.depth));

      if (c.showLabels && (labelled.contains(t.id) || c.targets.length <= budget)) {
        labels.add((t, col, top, orbR, selected, topP.depth));
      }
    }

    // Labels last (always on top), nearest/selected placed first; each tries
    // above, right, left, below its orb and is skipped if all collide.
    labels.sort((p, q) {
      if (p.$5 != q.$5) return p.$5 ? -1 : 1;
      return p.$6.compareTo(q.$6);
    });
    final placed = <Rect>[];
    for (final (t, col, top, orbR, selected, _) in labels) {
      _drawLabel(canvas, th, t, col, top, orbR, selected, placed);
    }
  }

  void _drawLabel(
    Canvas canvas,
    Radar3DTheme th,
    RadarTarget t,
    Color col,
    Offset top,
    double orbR,
    bool selected,
    List<Rect> placed,
  ) {
    final name = t.label.length > 16 ? '${t.label.substring(0, 15)}…' : t.label;
    final title = _label(name, TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: th.labelText, height: 1.2));
    final showTrend = !t.stale && (t.trend == ProximityTrend.closing || t.trend == ProximityTrend.receding);
    final dist = _label(
      '${t.hasPosition ? '' : '≈'}${_fmtMeters(t.meters)} m${t.stale ? ' · lost' : ''}',
      TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: t.stale ? th.labelMuted : col,
        height: 1.2,
        fontFeatures: const [ui.FontFeature.tabularFigures()],
      ),
    );
    const padX = 10.0, gap = 7.0, dot = 7.0;
    final trendW = showTrend ? 13.0 : 0.0;
    final w = padX + dot + 6 + title.width + gap + dist.width + trendW + padX;
    final h = math.max(title.height, dist.height) + 10;
    final off = orbR + 10;
    final candidates = [
      Rect.fromCenter(center: top - Offset(0, off + h / 2), width: w, height: h),
      Rect.fromLTWH(top.dx + off * 0.7, top.dy - off * 0.7 - h, w, h),
      Rect.fromLTWH(top.dx - off * 0.7 - w, top.dy - off * 0.7 - h, w, h),
      Rect.fromLTWH(top.dx + off, top.dy - h / 2, w, h),
      Rect.fromLTWH(top.dx - off - w, top.dy - h / 2, w, h),
      Rect.fromCenter(center: top + Offset(0, off + h / 2), width: w, height: h),
      Rect.fromCenter(center: top - Offset(0, off + h * 1.5 + 6), width: w, height: h),
    ];
    // Keep labels inside the view: shift each candidate in from the edges.
    final bounds = Offset.zero & _fitSize;
    Rect inside(Rect r) {
      var dx = 0.0, dy = 0.0;
      if (r.left < 4) dx = 4 - r.left;
      if (r.right > bounds.right - 4) dx = bounds.right - 4 - r.right;
      if (r.top < 4) dy = 4 - r.top;
      if (r.bottom > bounds.bottom - 4) dy = bounds.bottom - 4 - r.bottom;
      return r.shift(Offset(dx, dy));
    }

    Rect? rect;
    for (final r in candidates.map(inside)) {
      if (!placed.any((p) => p.inflate(3).overlaps(r))) {
        rect = r;
        break;
      }
    }
    if (rect == null) {
      if (!selected) return; // no room — the orb itself still shows
      rect = inside(candidates.first);
    }
    placed.add(rect);
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(h / 2));
    _fill
      ..blendMode = BlendMode.srcOver
      ..color = th.labelBackground;
    canvas.drawRRect(rr, _fill);
    _stroke
      ..strokeWidth = selected ? 1.4 : 1
      ..color = col.withValues(alpha: selected ? 0.95 : 0.5);
    canvas.drawRRect(rr, _stroke);
    final cy = rect.center.dy;
    _fill.color = col;
    canvas.drawCircle(Offset(rect.left + padX + dot / 2, cy), dot / 2, _fill);
    var x = rect.left + padX + dot + 6;
    title.paint(canvas, Offset(x, cy - title.height / 2));
    x += title.width + gap;
    dist.paint(canvas, Offset(x, cy - dist.height / 2));
    if (showTrend) {
      // Vector trend arrow (no font glyph needed on any platform).
      final ax = x + dist.width + 8;
      final up = t.trend == ProximityTrend.closing;
      final tri = Path()
        ..moveTo(ax, up ? cy - 4.5 : cy + 4.5)
        ..lineTo(ax - 4.5, up ? cy + 3 : cy - 3)
        ..lineTo(ax + 4.5, up ? cy + 3 : cy - 3)
        ..close();
      _fill.color = up ? const Color(0xFF34D399) : const Color(0xFFFB7185);
      canvas.drawPath(tri, _fill);
    }
  }
}
