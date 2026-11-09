// A deterministic virtual room: a few BLE devices wander around, heard by
// this phone (observer "self", at the origin) and by three fixed hubs. The
// hubs make real trilateration possible for some devices; others are only
// heard by the phone (distance-only) — exactly like the real world.
import 'dart:math' as math;

import 'package:device_finder/device_finder.dart';

class SimDevice {
  SimDevice({
    required this.id,
    required this.name,
    required this.kind,
    required this.heardByHubs,
    required this.path,
    this.battery,
    this.txPower = -59,
    this.silentEvery,
  });

  final String id;
  final String name;
  final String kind;

  /// When true the hubs hear it too → trilaterated position.
  final bool heardByHubs;

  /// Position (m) at time t (s).
  final (double, double) Function(double t) path;

  final int? battery;
  final double txPower;

  /// (period, duration) seconds: goes silent to demo the stale state.
  final (double, double)? silentEvery;

  bool silentAt(double t) {
    final s = silentEvery;
    if (s == null) return false;
    return t % s.$1 > s.$1 - s.$2;
  }
}

class SimulatedWorld {
  SimulatedWorld({int seed = 7, DateTime? start}) : _rng = math.Random(seed), start = start ?? DateTime.now();

  final math.Random _rng;
  final DateTime start;
  double _t = 0;

  DateTime get now => start.add(Duration(microseconds: (_t * 1e6).round()));
  double get seconds => _t;

  static final List<AnchorPoint> hubs = [
    AnchorPoint(id: 'hub-a', x: -4.5, y: -2.5),
    AnchorPoint(id: 'hub-b', x: 4.5, y: -2.5),
    AnchorPoint(id: 'hub-c', x: 0.5, y: 6.0),
  ];

  final List<SimDevice> devices = [
    SimDevice(
      id: 'sim-airpods',
      name: 'AirPods Pro',
      kind: 'headphones',
      heardByHubs: true,
      battery: 82,
      path: (t) => (-1.6 + 1.3 * math.sin(t * 0.23), 2.4 + 0.9 * math.cos(t * 0.31)),
    ),
    SimDevice(
      id: 'sim-watch',
      name: 'Galaxy Watch',
      kind: 'watch',
      heardByHubs: true,
      battery: 64,
      path: (t) => (2.7 + 0.8 * math.cos(t * 0.19), -1.2 + 1.1 * math.sin(t * 0.27)),
    ),
    SimDevice(
      id: 'sim-keys',
      name: 'Keys',
      kind: 'tag',
      heardByHubs: false,
      battery: 41,
      path: (t) => (3.2 * math.sin(t * 0.07 + 1), 3.6 + 0.6 * math.cos(t * 0.11)),
    ),
    SimDevice(
      id: 'sim-buds',
      name: 'Pixel Buds',
      kind: 'headphones',
      heardByHubs: false,
      path: (t) => (-5.2, 4.4 + 0.3 * math.sin(t * 0.2)),
    ),
    SimDevice(
      id: 'sim-beacon',
      name: 'Desk beacon',
      kind: 'beacon',
      heardByHubs: false,
      txPower: -62,
      silentEvery: (40, 9),
      path: (t) => (-3.8, -5.6),
    ),
  ];

  /// Display info for every device (call once, then on changes).
  List<DeviceInfo> get infos => [
    for (final d in devices) DeviceInfo(id: d.id, name: d.name, displayName: d.name, kind: d.kind, batteryPercent: d.battery),
  ];

  double _gauss(double sigma) {
    final u1 = math.max(_rng.nextDouble(), 1e-12);
    final u2 = _rng.nextDouble();
    return sigma * math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  double _rssi(double meters, double txPower) => txPower - 28.0 * math.log(math.max(meters, 0.3)) / math.ln10 + _gauss(2.6);

  /// Advances the world by [dt] seconds and returns the samples heard.
  List<RssiSample> step(double dt) {
    _t += dt;
    final at = now;
    final out = <RssiSample>[];
    for (final d in devices) {
      if (d.silentAt(_t)) continue;
      final (x, y) = d.path(_t);
      out.add(RssiSample(deviceId: d.id, source: RssiSource.advertising, dbm: _rssi(math.sqrt(x * x + y * y), d.txPower), at: at));
      if (d.heardByHubs) {
        for (final h in hubs) {
          final dx = x - h.x, dy = y - h.y;
          out.add(
            RssiSample(
              deviceId: d.id,
              observerId: h.id,
              source: RssiSource.advertising,
              dbm: _rssi(math.sqrt(dx * dx + dy * dy), d.txPower),
              at: at,
            ),
          );
        }
      }
    }
    return out;
  }
}
