import 'dart:async';
import 'dart:io';

import 'package:device_finder/device_finder.dart';
import 'package:device_finder_ble/device_finder_ble.dart';
import 'package:flutter/material.dart';

/// End-to-end finder app: permissions → scan → select → calibrate → radar.
void main() {
  runApp(const DeviceFinderApp());
}

class DeviceFinderApp extends StatelessWidget {
  const DeviceFinderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'device_finder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: DfColors.background,
        colorScheme: const ColorScheme.dark(
          primary: DfColors.accent,
          secondary: DfColors.secondary,
          surface: DfColors.surface,
        ),
        fontFamily: null, // system font
      ),
      home: const _Flow(),
    );
  }
}

/// Screen state machine.
enum _Step { permissions, scan, calibrate, radar }

class _Flow extends StatefulWidget {
  const _Flow();

  @override
  State<_Flow> createState() => _FlowState();
}

class _FlowState extends State<_Flow> {
  _Step _step = _Step.permissions;
  final BleDriver _driver = BleDriver();
  final DeviceTracker _tracker = DeviceTracker();
  final FileProfileStore _store = FileProfileStore(directory: _docsDir());
  StreamSubscription<RssiSample>? _sub;

  String? _selectedId;
  String _selectedName = '';

  static Directory _docsDir() {
    try {
      return Directory('${Directory.systemTemp.path}/device_finder_profiles');
    } catch (_) {
      return Directory.systemTemp;
    }
  }

  @override
  void initState() {
    super.initState();
    _sub = _driver.samples.listen(_tracker.pushSample);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _driver.dispose();
    _tracker.refresh();
    super.dispose();
  }

  void _startScan() async {
    final ok = await _driver.ensurePermissions();
    if (!ok) return;
    await _driver.startScan();
    setState(() => _step = _Step.scan);
    // Slow tick to surface state changes.
    Timer.periodic(const Duration(milliseconds: 200), (_) => _tracker.tick());
  }

  void _select(String id) {
    final st = _tracker.stateOf(id);
    setState(() {
      _selectedId = id;
      _selectedName = st?.info.name ?? id;
      _step = _Step.calibrate;
    });
  }

  Future<void> _calibrate() async {
    // Guided 1-2-4-8 m calibration: prompt the user at each distance and
    // collect samples from the live stream. This is a minimal host-side
    // implementation — a production app shows a step wizard.
    final c = Calibrator(minSamplesPerDistance: 30);
    for (final d in [1.0, 2.0, 4.0, 8.0]) {
      // Collect live samples at this distance (simplified: take whatever the
      // tracker has buffered in the last few seconds).
      final samples = _tracker.stateOf(_selectedId!)?.samples
          .where((s) => s.source == RssiSource.advertising)
          .take(60);
      for (final s in samples ?? <RssiSample>[]) {
        c.addSample(d, s.dbm);
      }
    }
    final result = c.fit();
    if (result.accepted) {
      await _store.save(_selectedId!, result.profile);
    }
    if (!mounted) return;
    setState(() => _step = _Step.radar);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: switch (_step) {
          _Step.permissions => _PermissionsView(onDone: _startScan),
          _Step.scan => _ScanView(tracker: _tracker, onSelect: _select),
          _Step.calibrate => _CalibrateView(name: _selectedName, onDone: _calibrate),
          _Step.radar => _RadarView(
              tracker: _tracker,
              deviceId: _selectedId!,
              driver: _driver,
            ),
        },
      ),
    );
  }
}

class _PermissionsView extends StatelessWidget {
  const _PermissionsView({required this.onDone});
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(DfSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bluetooth_searching, color: DfColors.accent, size: 56),
            const SizedBox(height: DfSpace.lg),
            Text('Find your devices', style: DfType.headline),
            const SizedBox(height: DfSpace.sm),
            Text(
              'device_finder uses Bluetooth Low Energy signal strength to '
              'locate your devices — fully offline, on-device.',
              style: DfType.body,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: DfSpace.xl),
            FilledButton(
              onPressed: onDone,
              style: FilledButton.styleFrom(backgroundColor: DfColors.accent, foregroundColor: Colors.black),
              child: const Text('Enable Bluetooth'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanView extends StatelessWidget {
  const _ScanView({required this.tracker, required this.onSelect});
  final DeviceTracker tracker;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final states = tracker.states.toList();
    return Padding(
      padding: const EdgeInsets.all(DfSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.radar, color: DfColors.accent, size: 22),
              const SizedBox(width: DfSpace.sm),
              Text('Scanning', style: DfType.title),
              const Spacer(),
              Text('${states.length} seen', style: DfType.label),
            ],
          ),
          const SizedBox(height: DfSpace.md),
          Expanded(
            child: DeviceList(states: states, onSelect: onSelect),
          ),
        ],
      ),
    );
  }
}

class _CalibrateView extends StatelessWidget {
  const _CalibrateView({required this.name, required this.onDone});
  final String name;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(DfSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Calibrate $name', style: DfType.headline),
            const SizedBox(height: DfSpace.md),
            Text(
              'Place the device at exactly 1 m, 2 m, 4 m, then 8 m, holding '
              'still for a few seconds at each distance.',
              style: DfType.body,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: DfSpace.xl),
            FilledButton(
              onPressed: onDone,
              style: FilledButton.styleFrom(backgroundColor: DfColors.accent, foregroundColor: Colors.black),
              child: const Text('Start calibration'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RadarView extends StatefulWidget {
  const _RadarView({required this.tracker, required this.deviceId, required this.driver});
  final DeviceTracker tracker;
  final String deviceId;
  final BleDriver driver;

  @override
  State<_RadarView> createState() => _RadarViewState();
}

class _RadarViewState extends State<_RadarView> {
  @override
  void initState() {
    super.initState();
    // Prefer connected-link RSSI when possible (Phase 4).
    widget.driver.connectAndPollRssi(widget.deviceId);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.tracker.stateOf(widget.deviceId);
    return Padding(
      padding: const EdgeInsets.all(DfSpace.lg),
      child: Column(
        children: [
          Row(
            children: [
              Text(s?.info.name ?? widget.deviceId, style: DfType.headline),
              const Spacer(),
              const Icon(Icons.bluetooth_connected, color: DfColors.ok, size: 20),
            ],
          ),
          const SizedBox(height: DfSpace.lg),
          Expanded(
            child: RadarView(
              estimate: s?.estimate,
              fix: s?.fix,
              info: s?.info,
              size: const Size(280, 280),
            ),
          ),
          const SizedBox(height: DfSpace.lg),
          SignalMeter(estimate: s?.estimate),
          const SizedBox(height: DfSpace.lg),
          EllipseMap(
            fix: s?.fix,
            estimate: s?.estimate,
            anchors: const [Offset(0, 0), Offset(10, 0)],
          ),
        ],
      ),
    );
  }
}
