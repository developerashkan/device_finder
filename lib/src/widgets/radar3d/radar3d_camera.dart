/// Orbit camera for the 3D radar — pure math, no Flutter widgets.
///
/// World space ("disc units"): the radar disc has radius 1, `x` points right,
/// `y` points forward (away from the user), `z` points up. The camera orbits
/// the disc center at [Radar3DCamera.distance], tilted by [pitch] above the
/// ground plane and turned by [yaw] around the vertical axis.
library;

import 'dart:math' as math;

/// A projected point: offset from the disc center in unit screen space
/// (multiply by the fit scale for pixels; +y is down) plus camera depth.
class ProjectedPoint {
  const ProjectedPoint(this.x, this.y, this.depth, this.scale);

  final double x;
  final double y;

  /// Distance along the view axis (larger = farther away).
  final double depth;

  /// Perspective scale at this depth (1.0 at the disc center).
  final double scale;
}

class Radar3DCamera {
  Radar3DCamera({double yaw = 0, double pitch = 1.0, this.distance = 3.4}) {
    set(yaw, pitch);
  }

  /// Camera distance from the disc center, in disc radii. Smaller values give
  /// stronger perspective.
  final double distance;

  double _yaw = 0, _pitch = 1;
  double _cy = 1, _sy = 0, _cp = 1, _sp = 0;

  /// Rotation around the vertical axis (radians).
  double get yaw => _yaw;

  /// Elevation above the ground plane (radians); π/2 is straight top-down.
  double get pitch => _pitch;

  /// Smallest/largest supported pitch (keeps the disc readable).
  static const double minPitch = 20 * math.pi / 180;
  static const double maxPitch = 89 * math.pi / 180;

  void set(double yaw, double pitch) {
    _yaw = yaw;
    _pitch = pitch.clamp(minPitch, maxPitch);
    _cy = math.cos(_yaw);
    _sy = math.sin(_yaw);
    _cp = math.cos(_pitch);
    _sp = math.sin(_pitch);
  }

  /// Projects a world point (disc units) to unit screen space.
  ProjectedPoint project(double x, double y, double z) {
    final xr = x * _cy - y * _sy;
    final yr = x * _sy + y * _cy;
    final up = yr * _sp + z * _cp;
    final depth = yr * _cp - z * _sp + distance;
    final k = distance / math.max(depth, 0.05);
    return ProjectedPoint(xr * k, -up * k, depth, k);
  }

  /// Bounding box `(left, top, right, bottom)` in unit screen space of the
  /// disc (radius [radius]) including content up to height [maxHeight].
  /// Independent of yaw because the disc is rotationally symmetric.
  (double, double, double, double) discBounds({double radius = 1.2, double maxHeight = 0.65}) {
    var l = double.infinity, t = double.infinity, r = -double.infinity, b = -double.infinity;
    const steps = 72;
    for (var i = 0; i < steps; i++) {
      final a = i * 2 * math.pi / steps;
      for (final z in [0.0, maxHeight]) {
        final p = project(radius * math.sin(a), radius * math.cos(a), z);
        l = math.min(l, p.x);
        r = math.max(r, p.x);
        t = math.min(t, p.y);
        b = math.max(b, p.y);
      }
    }
    return (l, t, r, b);
  }
}
