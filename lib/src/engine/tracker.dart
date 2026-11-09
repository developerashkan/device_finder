/// `DeviceTracker` — the zero-latency orchestration core.
///
/// Purely synchronous: every sample pushes straight through Kalman → fusion
/// → path-loss → trilateration → mirror resolution with no scheduling, no
/// Futures, no channels. The UI reads [DeviceTracker.stateOf] /
/// [DeviceTracker.states] and repaints via [DeviceTracker.stateNotifier].
/// Silence surfaces as staleness (never extrapolated positions).
///
/// ## Observers and anchors
///
/// Every [RssiSample] carries an `observerId` — the radio that heard the
/// packet. Samples from different observers are filtered **independently**
/// (one fusion window + Kalman filter per observer), because RSSI heard by
/// two radios at two places describes two different distances.
///
/// * The [DeviceTracker.selfObserverId] observer (default `'self'`, this
///   phone) drives [TrackedDeviceState.estimate] — "how far is it from me".
/// * When anchors are provided, each [AnchorPoint.id] is matched to the
///   observer with the same id. With ≥ 3 fresh anchors the position is solved
///   by weighted Gauss–Newton trilateration; with exactly 2 the closed-form
///   pair is solved and the mirror ambiguity is resolved from movement
///   history. Fewer than 2 fresh anchors means distance-only (no fix) — the
///   engine never invents a direction.
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
    this.selfObserverId = 'self',
    this.maxObserversPerDevice = 16,
  })  : _profileResolver = profileResolver ?? ((_) => CalibrationProfile.defaults),
        _anchorsProvider = anchorsProvider ?? (() => const []),
        updatePeriod = updatePeriod ?? const Duration(milliseconds: 100);

  /// Group devices that advertise the same non-empty name (rotating MACs).
  final bool useNameAsGroupingKey;

  /// Observer id of this phone; its samples drive the distance estimate.
  final String selfObserverId;

  /// Hard cap on per-device observer channels (bounds memory if a driver
  /// emits unbounded observer ids).
  final int maxObserversPerDevice;

  /// Resolves the calibration profile for a device (offline store in
  /// production; injected so the engine stays plugin-free).
  final CalibrationProfile Function(String deviceId) _profileResolver;

  /// Provides anchor positions for trilateration (empty = distance-only).
  final List<AnchorPoint> Function() _anchorsProvider;

  /// How often the UI/callee should call [tick]; samples can arrive faster.
  final Duration updatePeriod;

  final Map<String, _PerDevice> _devices = {};
  final Map<String, String> _idToGroupId = {};
  final _stateNotifier = ChangeNotifier();

  /// Binds the UI: `CustomPainter(scene) : super(repaint: tracker.stateNotifier)`.
  /// One notifier repaints every attached painter on the same frame.
  Listenable get stateNotifier => _stateNotifier;

  /// Number of tracked (grouped) devices.
  int get deviceCount => _devices.length;

  void pushSample(RssiSample sample) {
    if (!sample.dbm.isFinite || sample.dbm > 20 || sample.dbm < -150) {
      return; // driver garbage — never let NaN/absurd values into the filters
    }
    final targetId = _idToGroupId[sample.deviceId] ?? sample.deviceId;
    _per(targetId, sample.deviceId).push(sample);
  }

  /// Attaches identity/display info for a device.
  ///
  /// When name grouping moves a device into a different group, everything
  /// already collected under its previous key is carried over, so no
  /// orphaned "ghost" entry is left behind.
  void setInfo(DeviceInfo info) {
    var targetId = info.id;
    final name = info.name?.trim();
    if (useNameAsGroupingKey && name != null && name.isNotEmpty) {
      targetId = 'name:$name';
    }

    final previousKey = _idToGroupId[info.id] ?? info.id;
    _idToGroupId[info.id] = targetId;

    // Carry the old entry over only when this id was its sole member; a group
    // still shared with other ids keeps its data.
    final stillShared = _idToGroupId.entries.any((e) => e.key != info.id && e.value == previousKey);
    if (previousKey != targetId && !stillShared) {
      final orphan = _devices.remove(previousKey);
      if (orphan != null) {
        final existing = _devices[targetId];
        if (existing == null) {
          _devices[targetId] = orphan;
        } else {
          existing.absorb(orphan);
        }
      }
    }

    _per(targetId, info.id).info = info;
  }

  /// One full processing tick; call at [updatePeriod] or whenever samples
  /// arrive. Notifies listeners at most once, and only when something changed.
  void tick({DateTime? now}) {
    final t = now ?? DateTime.now();
    final anchors = _anchorsProvider();
    var changed = false;
    for (final d in _devices.values) {
      if (d.tick(t, anchors)) changed = true;
    }
    if (changed) _stateNotifier.notifyListeners();
  }

  TrackedDeviceState? stateOf(String deviceId) {
    final d = _devices[_idToGroupId[deviceId] ?? deviceId];
    return d?.snapshot();
  }

  Iterable<TrackedDeviceState> get states sync* {
    for (final d in _devices.values) {
      yield d.snapshot();
    }
  }

  /// Applies a calibration profile to a live device (e.g. right after a
  /// calibration run) and repaints. Returns false when the device is unknown.
  bool applyProfile(String deviceId, CalibrationProfile profile) {
    final d = _devices[_idToGroupId[deviceId] ?? deviceId];
    if (d == null) return false;
    d.profile = profile;
    _stateNotifier.notifyListeners();
    return true;
  }

  /// Re-resolves every device's profile through the `profileResolver`
  /// (after a profile store changed) and repaints.
  void reloadProfiles() {
    for (final d in _devices.values) {
      d.profile = _profileResolver(d.resolverKey);
    }
    _stateNotifier.notifyListeners();
  }

  /// Forgets a device (by its id or any id grouped with it).
  void forget(String deviceId) {
    final key = _idToGroupId[deviceId] ?? deviceId;
    if (_devices.remove(key) != null) _stateNotifier.notifyListeners();
    _idToGroupId.removeWhere((id, group) => group == key || id == deviceId);
  }

  /// Forgets everything.
  void clear() {
    _devices.clear();
    _idToGroupId.clear();
    _stateNotifier.notifyListeners();
  }

  _PerDevice _per(String key, String rawId) => _devices.putIfAbsent(
        key,
        () => _PerDevice(
          key: key,
          resolverKey: rawId,
          profile: _profileResolver(rawId),
          selfObserverId: selfObserverId,
          maxObservers: maxObserversPerDevice,
        ),
      );

  /// Notifies listeners even without new samples (used after anchor changes
  /// so the UI picks up new geometry).
  void refresh() => _stateNotifier.notifyListeners();
}

class AnchorPoint {
  AnchorPoint({required this.x, required this.y, required this.id});

  /// Position in meters (x right, y forward).
  final double x;
  final double y;

  /// Must equal the `observerId` of the samples this anchor hears.
  final String id;
}

/// One observer's independent filter chain for one device.
class _Channel {
  final SourceFusion fusion = SourceFusion();
  final RssiKalmanFilter kalman = RssiKalmanFilter();
  DateTime? lastSampleAt;
  DateTime? lastFedAt;
  double? filtered;
  bool initialized = false;

  void push(RssiSample s) {
    fusion.push(s);
    if (lastSampleAt == null || s.at.isAfter(lastSampleAt!)) lastSampleAt = s.at;
  }

  /// Runs the fusion window; feeds the Kalman filter only when new samples
  /// arrived since the last feed (re-feeding the same window would make the
  /// filter falsely confident during silence). Returns null when the
  /// observer has nothing (or only ghosts).
  ({double rssi, double sigma, RssiSource source, bool fresh})? evaluate(DateTime now) {
    final fused = fusion.estimate(now);
    if (fused == null) return null;
    final hasNew = lastSampleAt != null && (lastFedAt == null || lastSampleAt!.isAfter(lastFedAt!));
    if (fused.fresh && hasNew) {
      if (!initialized) {
        kalman.reset(fused.mean);
        initialized = true;
      }
      filtered = kalman.update(fused.mean, lastSampleAt!);
      lastFedAt = lastSampleAt;
    }
    final rssi = filtered ?? fused.mean;
    return (rssi: rssi, sigma: fused.sigma, source: fused.source, fresh: fused.fresh);
  }
}

class _PerDevice {
  _PerDevice({
    required this.key,
    required this.resolverKey,
    required CalibrationProfile profile,
    required this.selfObserverId,
    required this.maxObservers,
  })  : _profile = profile,
        _info = DeviceInfo(id: resolverKey);

  final String key;
  final String resolverKey;
  final String selfObserverId;
  final int maxObservers;

  CalibrationProfile _profile;
  set profile(CalibrationProfile p) => _profile = p;

  DeviceInfo _info;
  set info(DeviceInfo i) => _info = i;

  final Map<String, _Channel> _channels = {};
  final MirrorResolver _resolver = MirrorResolver();
  final List<RssiSample> _samples = [];
  DistanceEstimate? _lastEstimate;
  PositionFix? _lastFix;
  int? _lastAnchorSignature;
  ProximityTrend _trend = ProximityTrend.unknown;

  void push(RssiSample s) {
    var ch = _channels[s.observerId];
    if (ch == null) {
      if (_channels.length >= maxObservers) return;
      ch = _channels[s.observerId] = _Channel();
    }
    ch.push(s);
    _samples.add(s);
    if (_samples.length > 256) _samples.removeRange(0, _samples.length - 256);
  }

  /// Merges another entry (same physical device under an old key).
  void absorb(_PerDevice other) {
    final merged = [..._samples, ...other._samples]..sort((a, b) => a.at.compareTo(b.at));
    _samples.clear();
    _channels.clear();
    for (final s in merged) {
      push(s);
    }
  }

  /// The channel that answers "how far from me": this phone if it heard the
  /// device, otherwise the strongest observer.
  _Channel? _primary(DateTime now) {
    final self = _channels[selfObserverId];
    if (self != null && self.fusion.estimate(now) != null) return self;
    _Channel? best;
    double? bestMean;
    for (final ch in _channels.values) {
      final f = ch.fusion.estimate(now);
      if (f == null) continue;
      if (bestMean == null || f.mean > bestMean) {
        best = ch;
        bestMean = f.mean;
      }
    }
    return best ?? self;
  }

  bool tick(DateTime now, List<AnchorPoint> anchors) {
    final primary = _primary(now);
    final r = primary?.evaluate(now);

    if (r == null) {
      // Nothing valid: hold the last estimate as stale (never extrapolate).
      if (_lastEstimate == null || _lastEstimate!.isStale) return false;
      _lastEstimate = _stale(_lastEstimate!, now);
      if (_lastFix != null) _lastFix = _staleFix(_lastFix!, now);
      _trend = ProximityTrend.unknown;
      return true;
    }

    final d = distanceFromRssi(r.rssi, txPower: _profile.txPower, exponent: _profile.exponent);
    final dSigma = distanceSigma(d, r.sigma, exponent: _profile.exponent);
    _lastEstimate = DistanceEstimate(
      meters: d,
      sigmaMeters: dSigma,
      rssiDb: r.rssi,
      source: r.source,
      isStale: !r.fresh,
      at: now,
    );

    final v = primary!.kalman.velocity;
    _trend = !r.fresh
        ? ProximityTrend.unknown
        : v.abs() < 0.5
            ? ProximityTrend.stable
            : (v > 0 ? ProximityTrend.closing : ProximityTrend.receding);

    _solvePosition(now, anchors);
    return true;
  }

  void _solvePosition(DateTime now, List<AnchorPoint> anchors) {
    final signature = _anchorSignature(anchors);
    final anchorSetChanged = signature != _lastAnchorSignature;
    _lastAnchorSignature = signature;

    // Per-anchor distances from each anchor's own observer channel.
    final ranged = <Anchor>[];
    for (final a in anchors) {
      final ch = _channels[a.id];
      if (ch == null) continue;
      final r = ch.evaluate(now);
      if (r == null || !r.fresh) continue;
      final d = distanceFromRssi(r.rssi, txPower: _profile.txPower, exponent: _profile.exponent);
      final s = distanceSigma(d, r.sigma, exponent: _profile.exponent);
      ranged.add(Anchor(x: a.x, y: a.y, distance: d, sigma: math.max(s, 0.1)));
    }

    if (ranged.length >= 3) {
      final tf = solveTrilateration(ranged);
      if (!tf.x.isFinite || !tf.y.isFinite) return;
      _lastFix = PositionFix(
        x: tf.x,
        y: tf.y,
        covXX: tf.covXX,
        covYY: tf.covYY,
        covXY: tf.covXY,
        quality: math.sqrt(math.max(0.0, (tf.covXX + tf.covYY) / 2)),
        ambiguity: 0,
        status: FixStatus.fresh,
        at: now,
      );
    } else if (ranged.length == 2) {
      final pf = solveTwoAnchors(ranged[0], ranged[1]);
      final chosen = _resolver.resolve(a: pf.a, b: pf.b, at: now, anchorSetChanged: anchorSetChanged);
      final (major, minor) = _pairEllipse(pf, ranged);
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
    } else if (_lastFix != null && _lastFix!.status == FixStatus.fresh) {
      // Lost the geometry: keep the last fix but mark it stale.
      _lastFix = _staleFix(_lastFix!, now);
    }
  }

  (double, double) _pairEllipse(PairFix pf, List<Anchor> ranged) {
    final sep = math.sqrt((pf.a.$1 - pf.b.$1) * (pf.a.$1 - pf.b.$1) + (pf.a.$2 - pf.b.$2) * (pf.a.$2 - pf.b.$2));
    final sigma = math.max(ranged[0].sigma, ranged[1].sigma);
    return (math.max(sep / 2, sigma), math.max(0.5, sigma * 0.6));
  }

  int _anchorSignature(List<AnchorPoint> anchors) {
    var h = anchors.length;
    for (final a in anchors) {
      h = Object.hash(h, a.id, a.x, a.y);
    }
    return h;
  }

  static DistanceEstimate _stale(DistanceEstimate e, DateTime now) => DistanceEstimate(
        meters: e.meters,
        sigmaMeters: e.sigmaMeters,
        rssiDb: e.rssiDb,
        source: e.source,
        isStale: true,
        at: now,
      );

  static PositionFix _staleFix(PositionFix f, DateTime now) => PositionFix(
        x: f.x,
        y: f.y,
        covXX: f.covXX,
        covYY: f.covYY,
        covXY: f.covXY,
        quality: f.quality,
        ambiguity: f.ambiguity,
        status: FixStatus.stale,
        at: now,
      );

  TrackedDeviceState snapshot() {
    DateTime? lastSeen;
    for (final s in _samples) {
      if (lastSeen == null || s.at.isAfter(lastSeen)) lastSeen = s.at;
    }
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
}
