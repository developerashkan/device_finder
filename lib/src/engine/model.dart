/// Core data model for the `device_finder` signal engine.
///
/// Everything here is immutable data — no Flutter imports. The engine is a
/// pure-Dart module (dart:math / dart:async / dart:collection only) so it can
/// be tested headlessly and reused outside the widget tree.
library;

import 'dart:math' as math;

/// Where an RSSI observation came from.
///
/// Connected-link RSSI (GATT `readRemoteRssi` / `readRSSI`) is cleaner than
/// passively scanned advertisements (σ ≈ 4 dB vs σ ≈ 7 dB) and is preferred
/// whenever a link is established — see [SourceFusion].
enum RssiSource {
  /// Passively observed advertisement packet.
  advertising,

  /// RSSI read over an established GATT connection (link supervision).
  connectedLink,
}

/// One RSSI observation of a device, tagged with its source and observer.
class RssiSample {
  RssiSample({
    required this.deviceId,
    required this.source,
    required this.dbm,
    required this.at,
    this.observerId = 'self',
    this.txPower,
  });

  /// Stable engine key for the device (driver-provided; may be a rotating
  /// MAC — identity grouping is the caller's concern via [DeviceInfo]).
  final String deviceId;

  /// Source of this sample (advertising vs connected link).
  final RssiSource source;

  /// Received signal strength in dBm (negative).
  final double dbm;

  /// Platform timestamp of the radio observation.
  final DateTime at;

  /// Identifier of the observer (anchor) that heard this packet.
  final String observerId;

  /// Advertised TX power (AD type 0x0A) if the device broadcasts it — a free
  /// calibration reference.
  final double? txPower;
}

/// Identity / display info for a tracked device.
class DeviceInfo {
  DeviceInfo({
    required this.id,
    this.name,
    this.displayName,
    this.kind,
    this.batteryPercent,
  });

  final String id;

  /// Raw advertised name (may be empty or rotating).
  final String? name;

  /// Grouping key used by the UI device list (falls back to kind or id).
  final String? displayName;

  /// Vendor/kind hint, e.g. 'AirPods', 'Beacon', 'Unknown'.
  final String? kind;

  /// Battery charge 0-100 when the device exposes the Battery Service
  /// (0x180F / 0x2A19); null when unknown.
  final int? batteryPercent;
}

/// Distance estimate derived from fused, filtered RSSI.
class DistanceEstimate {
  DistanceEstimate({
    required this.meters,
    required this.sigmaMeters,
    required this.rssiDb,
    required this.source,
    required this.isStale,
    required this.at,
  });

  /// Distance in meters (clamped to [0.5, 30] by the path-loss model).
  final double meters;

  /// 1σ uncertainty of the distance estimate in meters.
  final double sigmaMeters;

  /// Filtered RSSI (dBm) that produced this estimate.
  final double rssiDb;

  /// Winning source for the fusion window.
  final RssiSource source;

  /// True when no fresh samples have arrived for [stalenessAfter] seconds.
  final bool isStale;

  final DateTime at;
}

/// A resolved 2-D position fix.
class PositionFix {
  PositionFix({
    required this.x,
    required this.y,
    required this.covXX,
    required this.covYY,
    required this.covXY,
    required this.quality,
    required this.status,
    required this.at,
    this.ambiguity = 0,
  });

  final double x;
  final double y;

  /// 2×2 covariance of the fix (m²), symmetric: [[covXX, covXY], [covXY, covYY]].
  final double covXX;
  final double covYY;
  final double covXY;

  /// Aggregate 1σ error (m): sqrt(trace/2), or the radial sigma for 1-anchor.
  final double quality;

  /// 0 = unique fix, 1 = two mirror candidates resolved, 2 = ambiguous.
  final int ambiguity;

  final FixStatus status;
  final DateTime at;

  /// Semi-axes of the 95% confidence ellipse (χ²₂ = 5.991, scale 2.447),
  /// as `(major, minor, thetaDeg)`.
  (double, double, double) confidenceEllipse() {
    final t = covXX + covYY;
    final d = covXX * covYY - covXY * covXY;
    final disc = math.sqrt(math.max(0.0, t * t - 4 * d));
    final l1 = (t + disc) / 2;
    final l2 = (t - disc) / 2;
    final theta = 0.5 * math.atan2(2 * covXY, covXX - covYY);
    return (2.447 * math.sqrt(l1), 2.447 * math.sqrt(l2), theta * 180 / math.pi);
  }
}

enum FixStatus {
  /// Fresh fix with at least one observer.
  fresh,

  /// Estimate held, but samples are stale — position is not extrapolated.
  stale,
}

/// A fitted calibration profile (TxPower/exponent) for one device.
class CalibrationProfile {
  CalibrationProfile({
    required this.txPower,
    required this.exponent,
    required this.residualRmsDb,
    required this.calibratedAt,
    this.distancesUsed = const [1, 2, 4, 8],
    this.samplesPerDistance = 0,
  });

  /// TX power (dBm) at 1 meter.
  final double txPower;

  /// Path-loss exponent n.
  final double exponent;

  /// RMS residual of the fit (dB) — accepted only when ≤ 8.
  final double residualRmsDb;

  final DateTime calibratedAt;

  /// Distances (m) at which samples were collected.
  final List<double> distancesUsed;

  final int samplesPerDistance;

  /// Shared default profile: −59 dBm @ 1 m, exponent 2.8.
  static final CalibrationProfile defaults = CalibrationProfile(
    txPower: -59.0,
    exponent: 2.8,
    residualRmsDb: 0,
    calibratedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );

  bool get isDefault => calibratedAt.millisecondsSinceEpoch == 0;

  Map<String, Object> toJson() => {
        'txPower': txPower,
        'exponent': exponent,
        'residualRmsDb': residualRmsDb,
        'calibratedAt': calibratedAt.toIso8601String(),
        'distancesUsed': distancesUsed,
        'samplesPerDistance': samplesPerDistance,
      };

  factory CalibrationProfile.fromJson(Map<String, Object?> json) {
    return CalibrationProfile(
      txPower: (json['txPower'] as num).toDouble(),
      exponent: (json['exponent'] as num).toDouble(),
      residualRmsDb: (json['residualRmsDb'] as num?)?.toDouble() ?? 0,
      calibratedAt: DateTime.parse(json['calibratedAt'] as String),
      distancesUsed: ((json['distancesUsed'] as List?) ?? const [1, 2, 4, 8])
          .map((e) => (e as num).toDouble())
          .toList(),
      samplesPerDistance: (json['samplesPerDistance'] as num?)?.toInt() ?? 0,
    );
  }
}

enum ProximityTrend {
  /// Closing in (getting closer).
  closing,

  /// Receding (getting further away).
  receding,

  /// No significant change in distance.
  stable,

  /// Not enough data yet.
  unknown,
}

/// Live, per-device tracking state — what the UI binds to.
class TrackedDeviceState {
  TrackedDeviceState({
    required this.info,
    this.estimate,
    this.fix,
    this.samples = const [],
    this.lastSeen,
    this.profile,
    this.trend = ProximityTrend.unknown,
  });

  final DeviceInfo info;
  final DistanceEstimate? estimate;
  final PositionFix? fix;
  final List<RssiSample> samples;
  final DateTime? lastSeen;
  final CalibrationProfile? profile;
  final ProximityTrend trend;

  factory TrackedDeviceState.empty(DeviceInfo info) => TrackedDeviceState(
        info: info,
        estimate: null,
        fix: null,
        samples: const [],
        lastSeen: null,
        profile: null,
        trend: ProximityTrend.unknown,
      );

  bool get hasSignal => lastSeen != null && estimate != null && !estimate!.isStale;
}
