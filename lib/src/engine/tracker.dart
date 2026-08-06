/// `DeviceTracker` — the zero-latency orchestration core.
///
/// Purely synchronous: every sample pushes straight through Kalman → fusion
/// → path-loss → trilateration → mirror resolution with no scheduling, no
/// Futures, no channels. The UI reads [state] and repaints via the bound
/// Listenable. Silence surfaces as staleness (never extrapolated positions).
library;

import 'dart:math' as math;

import 'notify.dart';
import 'fusion/source_fusion.dart';
import 'kalman/kalman_filter.dart';
import 'model.dart';
import 'path_loss.dart';
import 'trilateration/mirror_resolver.dart';
import 'trilateration/trilateration.dart';

class DeviceTracker {
  DeviceTracker({
    CalibrationProfile Function(String deviceId)? profileResolver,
    List<AnchorPoint> Function()? anchorsProvider,
    Duration? updatePeriod,
    this.useNameAsGroupingKey = true,
  })  : _profileResolver = profileResolver ?? ((_) => CalibrationProfile.defaults),
        _anchorsProvider = anchorsProvider ?? (() => const []),
        updatePeriod = updatePeriod ?? const Duration(milliseconds: 100);

  final bool useNameAsGroupingKey;

  /// Resolves the calibration profile for a device (offline store in
  /// production; injected so the engine stays plugin-free).
  final CalibrationProfile Function(String deviceId) _profileResolver;

  /// Provides anchor positions for trilateration (empty = single-observer
  /// distance-only mode).
  final List<AnchorPoint> Function() _anchorsProvider;

  /// How often the UI/callee should read [state] (and how often haptics
  /// re-evaluate); samples can arrive much faster.
  final Duration updatePeriod;

  final Map<String, _PerDevice> _devices = {};
  final Map<String, String> _idToGroupId = {};
  final _stateNotifier = ChangeNotifier();

  /// Binds the UI: `CustomPainter(scene) : super(repaint: tracker.stateNotifier)`.
  /// One notifier repaints every attached painter on the same frame.
  Listenable get stateNotifier => _stateNotifier;

  void pushSample(RssiSample sample) {
    final targetId = _idToGroupId[sample.deviceId] ?? sample.deviceId;
    _per(targetId).push(sample);
  }

  /// Attaches identity/display info for a device.
  void setInfo(DeviceInfo info) {
    final existingGroupId = _idToGroupId[info.id];
    
    String targetId = info.id;
    if (useNameAsGroupingKey && info.name != null && info.name!.isNotEmpty) {
      targetId = 'name:${info.name}';
    }

    if (existingGroupId != null && existingGroupId != targetId) {
      // ID was previously mapped to a different group. 
      // This could happen if a device changed names or we're re-grouping.
      // For simplicity, we'll just update the mapping.
    }
    
    _idToGroupId[info.id] = targetId;
    
    final p = _per(targetId);
    p.info = info;
  }

  /// One full processing tick; call at [updatePeriod] or whenever samples
  /// arrive. Notifies listeners only when something changed.
  void tick({DateTime? now}) {
    final t = now ?? DateTime.now();
    for (final d in _devices.values) {
      if (d.tick(t)) _stateNotifier.notifyListeners();
    }
  }

  TrackedDeviceState? stateOf(String deviceId) {
    final targetId = _idToGroupId[deviceId] ?? deviceId;
    final d = _devices[targetId];
    if (d == null) return null;
    return d.snapshot();
  }

  Iterable<TrackedDeviceState> get states sync* {
    final t = DateTime.now();
    for (final d in _devices.values) {
      yield d.snapshot(t);
    }
  }

  void forget(String deviceId) => _devices.remove(deviceId);

  _PerDevice _per(String id) =>
      _devices.putIfAbsent(id, () => _PerDevice(_profileResolver(id), anchorsProvider: _anchorsProvider));

  /// Notifies listeners even without new samples (used after calibration or
  /// anchor changes so the UI picks up new profiles/geometry).
  void refresh() => _stateNotifier.notifyListeners();
}

class AnchorPoint {
  AnchorPoint({required this.x, required this.y, required this.id});
  final double x;
  final double y;
  final String id;
}

class _PerDevice {
  _PerDevice(
    CalibrationProfile initialProfile, {
    required List<AnchorPoint> Function() anchorsProvider,
  })  : _profile = initialProfile,
        _anchorsProvider = anchorsProvider;

  CalibrationProfile _profile;

  /// Anchor geometry provider shared with the tracker.
  final List<AnchorPoint> Function() _anchorsProvider;
  final SourceFusion _fusion = SourceFusion();
  final RssiKalmanFilter _kalman = RssiKalmanFilter();
  final MirrorResolver _resolver = MirrorResolver();
  final List<RssiSample> _samples = [];
  DistanceEstimate? _lastEstimate;
  PositionFix? _lastFix;
  int _lastAnchorSet = -1;

  void setProfile(CalibrationProfile p) => _profile = p;

  void push(RssiSample s) {
    _fusion.push(s);
    _samples.add(s);
    if (_samples.length > 256) _samples.removeRange(0, _samples.length - 256);
  }

  bool tick(DateTime now) {
    final fused = _fusion.estimate(now);

    if (fused == null) {
      if (_lastEstimate != null && _lastEstimate!.isStale) return false;
      // No signal at all: keep last estimate, mark stale (handled below).
      if (_lastEstimate != null) {
        _lastEstimate = DistanceEstimate(
          meters: _lastEstimate!.meters,
          sigmaMeters: _lastEstimate!.sigmaMeters,
          rssiDb: _lastEstimate!.rssiDb,
          source: _lastEstimate!.source,
          isStale: true,
          at: now,
        );
        _lastFix = _lastFix == null ? null : PositionFix(
              x: _lastFix!.x,
              y: _lastFix!.y,
              covXX: _lastFix!.covXX,
              covYY: _lastFix!.covYY,
              covXY: _lastFix!.covXY,
              quality: _lastFix!.quality,
              ambiguity: _lastFix!.ambiguity,
              status: FixStatus.stale,
              at: now,
            );
        return true;
      }
      return false;
    }

    // Kalman smooths the winning source's mean.
    final filtered = _kalman.update(fused.mean, now);
    final d = distanceFromRssi(filtered, txPower: _profile.txPower, exponent: _profile.exponent);
    final dSigma = distanceSigma(d, fused.sigma, exponent: _profile.exponent);
    final estimate = DistanceEstimate(
      meters: d,
      sigmaMeters: dSigma,
      rssiDb: filtered,
      source: fused.source,
      isStale: !fused.fresh,
      at: now,
    );
    _lastEstimate = estimate;

    // Trilateration over provided anchors.
    final anchors = _anchorsProvider();
    final anchorSetChanged = _anchorSignature(anchors) != _lastAnchorSet;
    _lastAnchorSet = _anchorSignature(anchors);

    if (anchors.length >= 2) {
      final list = anchors
          .map((a) => Anchor(
                x: a.x,
                y: a.y,
                distance: d, // single-observer distance applied to each anchor
                sigma: dSigma,
              ))
          .toList();
      // TODO(phase2): per-anchor distances when multi-observer RSSI arrives.
      if (anchors.length == 2) {
        final pf = solveTwoAnchors(list[0], list[1]);
        final chosen = _resolver.resolve(
          a: pf.a,
          b: pf.b,
          at: now,
          anchorSetChanged: anchorSetChanged,
        );
        final (major, minor) = _pairEllipse(pf);
        _lastFix = PositionFix(
          x: chosen.$1,
          y: chosen.$2,
          covXX: major * major,
          covYY: minor * minor,
          covXY: 0,
          quality: (major + minor) / 2,
          ambiguity: pf.isDegenerate ? 2 : 1,
          status: FixStatus.fresh,
          at: now,
        );
      } else {
        final tf = solveTrilateration(list);
        _lastFix = PositionFix(
          x: tf.x,
          y: tf.y,
          covXX: tf.covXX,
          covYY: tf.covYY,
          covXY: tf.covXY,
          quality: math.sqrt((tf.covXX + tf.covYY) / 2),
          ambiguity: 0,
          status: FixStatus.fresh,
          at: now,
        );
      }
    } else if (anchors.length == 1) {
      // Single anchor: report at distance d along the last heading (or east).
      final a = anchors.first;
      final dir = _lastFix == null
          ? (1.0, 0.0)
          : _normalize(_lastFix!.x - a.x, _lastFix!.y - a.y);
      _lastFix = PositionFix(
        x: a.x + dir.$1 * d,
        y: a.y + dir.$2 * d,
        covXX: dSigma * dSigma,
        covYY: dSigma * dSigma,
        covXY: 0,
        quality: dSigma,
        ambiguity: 2,
        status: FixStatus.fresh,
        at: now,
      );
    } else {
      // Distance-only mode (no anchors): the estimate is the distance.
    }
    return true;
  }

  (double, double) _pairEllipse(PairFix pf) {
    final d1 = math.sqrt(
        (pf.a.$1 - pf.b.$1) * (pf.a.$1 - pf.b.$1) + (pf.a.$2 - pf.b.$2) * (pf.a.$2 - pf.b.$2));
    final axis = math.max(d1 / 2, 0.5);
    return (axis, 0.5);
  }

  (double, double) _normalize(double x, double y) {
    final n = math.sqrt(x * x + y * y);
    if (n < 1e-9) return (1, 0);
    return (x / n, y / n);
  }

  int _anchorSignature(List<AnchorPoint> anchors) {
    var h = 0;
    for (final a in anchors) {
      h = h * 31 + a.id.hashCode;
    }
    return h;
  }

  ProximityTrend get _trend {
    final v = _kalman.velocity;
    // Threshold in dB/s. 0.5 dB/s is a reasonable walking speed change.
    if (v.abs() < 0.5) return ProximityTrend.stable;
    return v > 0 ? ProximityTrend.closing : ProximityTrend.receding;
  }

  TrackedDeviceState snapshot([DateTime? now]) {
    final lastSeen = _samples.isEmpty ? null : _samples.last.at;
    return TrackedDeviceState(
      info: _info,
      estimate: _lastEstimate,
      fix: _lastFix,
      samples: List.unmodifiable(_samples),
      lastSeen: lastSeen,
      profile: _profile,
      trend: _trend,
    );
  }

  DeviceInfo _info = DeviceInfo(id: '');
  set info(DeviceInfo i) => _info = i;
}
