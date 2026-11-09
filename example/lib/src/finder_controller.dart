// Owns the tracker and whichever source feeds it (simulator or real BLE).
// Every timer and subscription is owned here and cancelled on mode switch
// and dispose — no leaks, no ticks after the screen is gone.
import 'dart:async';

import 'package:device_finder/device_finder.dart' as df;
import 'package:device_finder_ble/device_finder_ble.dart' as ble;
import 'package:flutter/foundation.dart';

import 'simulator.dart';

enum SourceMode { demo, live }

enum SourceStatus { starting, running, needsPermission, unavailable }

class FinderController extends ChangeNotifier {
  FinderController({this.autoRun = true, int seed = 7}) : _seed = seed {
    tracker = df.DeviceTracker(anchorsProvider: () => _mode == SourceMode.demo ? SimulatedWorld.hubs : const []);
    _startDemo();
  }

  /// When false (tests, screenshots) the simulator only moves via [advance].
  final bool autoRun;
  final int _seed;

  late final df.DeviceTracker tracker;

  SourceMode _mode = SourceMode.demo;
  SourceMode get mode => _mode;

  SourceStatus _status = SourceStatus.starting;
  SourceStatus get status => _status;

  String? _message;
  String? get message => _message;

  SimulatedWorld? _world;
  ble.BleDriver? _ble;
  Timer? _timer;
  StreamSubscription<df.RssiSample>? _samplesSub;
  StreamSubscription<df.DeviceInfo>? _infoSub;
  int _generation = 0;
  bool _disposed = false;

  /// Current time on the active source's clock.
  DateTime get now => _world?.now ?? DateTime.now();

  /// Number of fixed hubs helping to locate devices (demo only).
  int get hubCount => _mode == SourceMode.demo ? SimulatedWorld.hubs.length : 0;

  Future<void> setMode(SourceMode mode) async {
    if (mode == _mode && _status != SourceStatus.unavailable && _status != SourceStatus.needsPermission) return;
    _mode = mode;
    await _stopAll();
    tracker.clear();
    if (mode == SourceMode.demo) {
      _startDemo();
    } else {
      await _startLive();
    }
  }

  /// Retries the current mode (after granting permission / enabling BT).
  Future<void> retry() async {
    await _stopAll();
    tracker.clear();
    if (_mode == SourceMode.demo) {
      _startDemo();
    } else {
      await _startLive();
    }
  }

  void _startDemo() {
    final world = _world = SimulatedWorld(seed: _seed);
    for (final info in world.infos) {
      tracker.setInfo(info);
    }
    // Warm up so the first frame already shows settled estimates.
    advance(3);
    _set(SourceStatus.running);
    if (autoRun) {
      _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _step(0.1));
    }
  }

  /// Moves the simulator forward by [seconds] (no-op in live mode).
  void advance(double seconds) {
    if (_world == null) return;
    var left = seconds;
    while (left > 1e-9) {
      final dt = left < 0.1 ? left : 0.1;
      _step(dt, notify: false);
      left -= dt;
    }
    tracker.tick(now: _world!.now);
  }

  void _step(double dt, {bool notify = true}) {
    final world = _world;
    if (world == null || _disposed) return;
    for (final s in world.step(dt)) {
      tracker.pushSample(s);
    }
    if (notify) tracker.tick(now: world.now);
  }

  Future<void> _startLive() async {
    final gen = ++_generation;
    _set(SourceStatus.starting);
    try {
      final driver = _ble = ble.BleDriver();
      final ok = await driver.ensurePermissions().timeout(const Duration(seconds: 12));
      if (gen != _generation || _disposed) return;
      if (!ok) {
        _set(SourceStatus.needsPermission, 'Bluetooth is off or permission was denied.');
        return;
      }
      _samplesSub = driver.samples.listen(tracker.pushSample, onError: (Object e) => _fail(gen, e));
      _infoSub = driver.info.listen(tracker.setInfo, onError: (Object e) => _fail(gen, e));
      await driver.startScan();
      if (gen != _generation || _disposed) return;
      _timer = Timer.periodic(const Duration(milliseconds: 150), (_) => tracker.tick());
      _set(SourceStatus.running);
    } on TimeoutException {
      _fail(gen, 'Bluetooth did not respond. Make sure it is turned on.');
    } catch (e) {
      _fail(gen, e);
    }
  }

  void _fail(int gen, Object error) {
    if (gen != _generation || _disposed) return;
    final text = error.toString();
    _set(
      SourceStatus.unavailable,
      text.contains('nsupported') || text.contains('MissingPlugin')
          ? 'Bluetooth scanning is not available on this platform.'
          : 'Could not start Bluetooth: $text',
    );
  }

  Future<void> _stopAll() async {
    _generation++;
    _timer?.cancel();
    _timer = null;
    await _samplesSub?.cancel();
    await _infoSub?.cancel();
    _samplesSub = null;
    _infoSub = null;
    final driver = _ble;
    _ble = null;
    if (driver != null) {
      try {
        await driver.stop();
        driver.dispose();
      } catch (_) {
        // Best effort: the adapter may already be gone.
      }
    }
    _world = null;
  }

  void _set(SourceStatus status, [String? message]) {
    if (_disposed) return;
    _status = status;
    _message = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_stopAll());
    super.dispose();
  }
}
