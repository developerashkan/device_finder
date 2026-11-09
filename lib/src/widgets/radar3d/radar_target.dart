/// What the 3D radar draws for one device.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../engine/model.dart';
import '../signal_meter/signal_meter.dart';

@immutable
class RadarTarget {
  const RadarTarget({
    required this.id,
    required this.label,
    required this.meters,
    this.x,
    this.y,
    this.sigmaMeters = 0,
    this.strength = 0.5,
    this.stale = false,
    this.trend = ProximityTrend.unknown,
    this.kind,
  });

  /// Builds a target from live tracker state; null while there is no
  /// distance estimate yet.
  static RadarTarget? fromState(TrackedDeviceState s) {
    final e = s.estimate;
    if (e == null || !e.meters.isFinite) return null;
    final fix = s.fix;
    final usableFix = fix != null && fix.x.isFinite && fix.y.isFinite;
    final name = s.info.displayName ?? s.info.name;
    return RadarTarget(
      id: s.info.id,
      label: (name == null || name.trim().isEmpty) ? _shortId(s.info.id) : name.trim(),
      meters: e.meters,
      x: usableFix ? fix.x : null,
      y: usableFix ? fix.y : null,
      sigmaMeters: e.sigmaMeters.isFinite ? e.sigmaMeters : 0,
      strength: strengthFromRssi(e.rssiDb),
      stale: e.isStale,
      trend: s.trend,
      kind: s.info.kind,
    );
  }

  /// All drawable targets from an iterable of states.
  static List<RadarTarget> fromStates(Iterable<TrackedDeviceState> states) =>
      [for (final s in states) if (fromState(s) case final t?) t];

  static String _shortId(String id) => id.length <= 8 ? id : '…${id.substring(id.length - 5)}';

  final String id;
  final String label;

  /// Distance from the observer (m).
  final double meters;

  /// Position (m, x right / y forward) when a trilaterated fix exists.
  final double? x;
  final double? y;

  /// 1σ distance uncertainty (m) — drawn as the width of the range band.
  final double sigmaMeters;

  /// Normalized signal strength 0..1 (drives pillar height and glow).
  final double strength;

  final bool stale;
  final ProximityTrend trend;
  final String? kind;

  /// True when direction is known (a position fix exists).
  bool get hasPosition => x != null && y != null;

  /// Stable 32-bit hash of [id]: FNV-1a plus a murmur3 finalizer so similar
  /// ids spread across the palette. Identical on every platform and run,
  /// unlike `String.hashCode`.
  int get stableHash {
    var h = 0x811c9dc5;
    for (final c in id.codeUnits) {
      h = mul32(h ^ c, 0x01000193);
    }
    h ^= h >>> 16;
    h = mul32(h, 0x7feb352d);
    h ^= h >>> 15;
    h = mul32(h, 0x846ca68b);
    h ^= h >>> 16;
    return h & 0xffffffff;
  }

  /// Exact `(a * b) mod 2^32` on every platform. A plain `a * b` exceeds
  /// 2^53 and silently loses precision on the web (JS doubles); splitting
  /// `a` into 16-bit halves keeps every intermediate product exact.
  static int mul32(int a, int b) {
    a &= 0xffffffff;
    b &= 0xffffffff;
    final lo = (a & 0xffff) * b; // < 2^48
    final hi = ((a >>> 16) * b) & 0xffff; // only its low 16 bits survive << 16
    return (lo + hi * 0x10000) & 0xffffffff;
  }

  /// Bearing (radians, clockwise from forward) at [timeSeconds]. With a fix
  /// it is the true bearing; without one the marker slowly orbits its range
  /// ring — honest about the unknown direction.
  double bearingAt(double timeSeconds) {
    if (hasPosition) return math.atan2(x!, y!);
    final h = stableHash;
    final phase = (h & 0xffff) / 0xffff * 2 * math.pi;
    final dir = (h >> 16) & 1 == 0 ? 1.0 : -1.0;
    return phase + dir * 0.16 * timeSeconds;
  }

  /// Distance used for layout: the fix radius when known, else [meters].
  double get radialMeters => hasPosition ? math.sqrt(x! * x! + y! * y!) : meters;

  @override
  bool operator ==(Object other) =>
      other is RadarTarget &&
      other.id == id &&
      other.label == label &&
      other.meters == meters &&
      other.x == x &&
      other.y == y &&
      other.sigmaMeters == sigmaMeters &&
      other.strength == strength &&
      other.stale == stale &&
      other.trend == trend &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(id, label, meters, x, y, sigmaMeters, strength, stale, trend, kind);
}
