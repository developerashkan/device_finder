import 'dart:async';
import 'package:device_finder/device_finder.dart' as df;
import 'package:device_finder_ble/device_finder_ble.dart' as ble;
import 'package:flutter/material.dart';

void main() => runApp(const DeviceFinderApp());

class DeviceFinderApp extends StatelessWidget {
  const DeviceFinderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'device_finder demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: df.DfColors.background,
        colorScheme: const ColorScheme.dark(
          primary: df.DfColors.accent,
          secondary: df.DfColors.secondary,
          surface: df.DfColors.surface,
        ),
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final df.DeviceTracker _tracker = df.DeviceTracker();
  final ble.BleDriver _ble = ble.BleDriver();
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _startBle();
  }

  Future<void> _startBle() async {
    final ok = await _ble.ensurePermissions();
    if (!ok) return;

    _sub = _ble.samples.listen((s) {
      _tracker.pushSample(s);
      _tracker.tick();
    });

    _ble.info.listen((info) {
      _tracker.setInfo(info);
    });

    await _ble.startScan();

    Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) _tracker.tick();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ble.stop();
    super.dispose();
  }

  String? _focusedId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _tracker.stateNotifier.toFlutter,
          builder: (context, _) {
            final states = _tracker.states.toList();
            return LayoutBuilder(
              builder: (context, constraints) {
                final isLandscape = constraints.maxWidth > constraints.maxHeight;

                final header = Row(
                  children: [
                    const Icon(Icons.radar, color: df.DfColors.accent, size: 24),
                    const SizedBox(width: df.DfSpace.sm),
                    Text('device_finder', style: df.DfType.headline),
                    const Spacer(),
                    Text('${states.length} real devices', style: df.DfType.label),
                  ],
                );

                final radar = Center(
                  child: SizedBox(
                    width: isLandscape ? constraints.maxHeight * 0.7 : 280,
                    height: isLandscape ? constraints.maxHeight * 0.7 : 280,
                    child: df.MultiRadarView(tracker: _tracker),
                  ),
                );

                final chips = SizedBox(
                  height: 34,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      _FocusChip(
                        label: 'All',
                        active: _focusedId == null,
                        onTap: () => setState(() => _focusedId = null),
                      ),
                      for (final s in states)
                        _FocusChip(
                          label: s.info.name ?? s.info.id,
                          active: _focusedId == s.info.id,
                          onTap: () => setState(() => _focusedId = s.info.id),
                        ),
                    ],
                  ),
                );

                final list = Expanded(
                  child: df.DeviceList(
                    states: states,
                    onSelect: (id) => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => RadarScreen(tracker: _tracker, deviceId: id),
                      ),
                    ),
                  ),
                );

                if (isLandscape) {
                  return Padding(
                    padding: const EdgeInsets.all(df.DfSpace.lg),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 2,
                          child: Column(
                            children: [
                              header,
                              const Spacer(),
                              radar,
                              const Spacer(),
                            ],
                          ),
                        ),
                        const SizedBox(width: df.DfSpace.lg),
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              chips,
                              const SizedBox(height: df.DfSpace.md),
                              list,
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return Padding(
                  padding: const EdgeInsets.all(df.DfSpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      header,
                      const SizedBox(height: df.DfSpace.md),
                      radar,
                      const SizedBox(height: df.DfSpace.md),
                      chips,
                      const SizedBox(height: df.DfSpace.md),
                      list,
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _FocusChip extends StatelessWidget {
  const _FocusChip({required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: df.DfSpace.sm),
      child: Material(
        color: active ? df.DfColors.accent : df.DfColors.surface,
        borderRadius: BorderRadius.circular(17),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(17),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: df.DfSpace.md),
            child: Center(
              child: Text(
                label.length > 10 ? '${label.substring(0, 7)}...' : label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: active ? Colors.black : df.DfColors.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RadarScreen extends StatefulWidget {
  const RadarScreen({super.key, required this.tracker, required this.deviceId});

  final df.DeviceTracker tracker;
  final String deviceId;

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen> {
  final df.GeigerHaptics _haptics = df.GeigerHaptics();
  bool _hapticsEnabled = false;

  @override
  void initState() {
    super.initState();
    if (_hapticsEnabled) _haptics.start(df.GeigerHaptics.intervalFor);
  }

  @override
  void dispose() {
    _haptics.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: df.DfColors.background,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.tracker.stateNotifier.toFlutter,
          builder: (context, _) {
            final s = widget.tracker.stateOf(widget.deviceId);
            final estimate = s?.estimate;
            if (_hapticsEnabled && estimate != null) _haptics.update(estimate.meters);
            final hint = df.directionFromFix(fix: s?.fix);
            
            String trendText = 'Scanning...';
            Color trendColor = df.DfColors.textSecondary;
            if (s != null) {
              switch (s.trend) {
                case df.ProximityTrend.closing:
                  trendText = 'CLOSING IN';
                  trendColor = Colors.greenAccent;
                  break;
                case df.ProximityTrend.receding:
                  trendText = 'RECEDING';
                  trendColor = Colors.redAccent;
                  break;
                case df.ProximityTrend.stable:
                  trendText = 'STABLE';
                  trendColor = Colors.blueAccent;
                  break;
                case df.ProximityTrend.unknown:
                  trendText = 'SEARCHING...';
                  break;
              }
            }

            return LayoutBuilder(
              builder: (context, constraints) {
                final isLandscape = constraints.maxWidth > constraints.maxHeight;

                final topBar = Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back, color: df.DfColors.textPrimary),
                    ),
                    const Spacer(),
                    if (estimate?.isStale ?? false)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: df.DfColors.danger.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text('NO SIGNAL', style: TextStyle(fontSize: 10, color: df.DfColors.danger, letterSpacing: 0.6)),
                      ),
                  ],
                );

                final radar = Center(
                  child: df.RadarView(
                    estimate: estimate,
                    fix: s?.fix,
                    info: s?.info,
                    trend: s?.trend ?? df.ProximityTrend.unknown,
                    size: isLandscape ? Size(constraints.maxHeight * 0.8, constraints.maxHeight * 0.8) : const Size(320, 320),
                  ),
                );

                final proximityCard = Container(
                  margin: EdgeInsets.only(top: 24),
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  decoration: BoxDecoration(
                    color: df.DfColors.surface,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: trendColor.withValues(alpha: 0.3), width: 1.5),
                    boxShadow: [
                      BoxShadow(color: trendColor.withValues(alpha: 0.1), blurRadius: 20, spreadRadius: 2),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        estimate == null ? '-- m' : '${estimate.meters.toStringAsFixed(1)} m',
                        style: TextStyle(fontSize: isLandscape ? 48 : 64, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -2.0),
                      ),
                      const SizedBox(height: 8),
                      Text(trendText, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: trendColor, letterSpacing: 2.0)),
                      const SizedBox(height: 16),
                      Text(s?.info.name ?? widget.deviceId, style: df.DfType.title, textAlign: TextAlign.center),
                      Text(widget.deviceId, style: df.DfType.label),
                      Text(
                        s?.info.batteryPercent != null
                            ? 'Battery : ${s!.info.batteryPercent}%'
                            : 'Battery : unknown',
                        style: df.DfType.body,
                      ),
                    ],
                  ),
                );

                final directionalHint = Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(df.DfSpace.lg),
                  decoration: BoxDecoration(
                    color: df.DfColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(df.DfRadius.large),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _DirIcon(icon: Icons.turn_left, active: hint == df.DirectionHint.left),
                          _DirIcon(icon: Icons.arrow_upward, active: hint == df.DirectionHint.forward),
                          _DirIcon(icon: Icons.turn_right, active: hint == df.DirectionHint.right),
                          _DirIcon(icon: Icons.u_turn_left, active: hint == df.DirectionHint.back),
                        ],
                      ),
                      const SizedBox(height: df.DfSpace.sm),
                      Text(hint.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)),
                      Text(hint.subtitle, style: df.DfType.label),
                      const SizedBox(height: df.DfSpace.md),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => setState(() {
                            _hapticsEnabled = !_hapticsEnabled;
                            if (_hapticsEnabled) _haptics.start(df.GeigerHaptics.intervalFor);
                          }),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: df.DfColors.textMuted),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                          ),
                          icon: Icon(_hapticsEnabled ? Icons.volume_up : Icons.volume_off, size: 18),
                          label: Text(_hapticsEnabled ? 'Mute' : 'Unmute'),
                        ),
                      ),
                    ],
                  ),
                );

                if (isLandscape) {
                  return Padding(
                    padding: const EdgeInsets.all(df.DfSpace.lg),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 1,
                          child: Column(
                            children: [
                              topBar,
                              Expanded(child: radar),
                            ],
                          ),
                        ),
                        const SizedBox(width: df.DfSpace.lg),
                        Expanded(
                          flex: 1,
                          child: SingleChildScrollView(
                            child: Column(
                              children: [
                                proximityCard,
                                const SizedBox(height: df.DfSpace.md),
                                directionalHint,
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return Padding(
                  padding: const EdgeInsets.all(df.DfSpace.lg),
                  child: Column(
                    children: [
                      topBar,
                      Expanded(child: radar),
                      proximityCard,
                      const SizedBox(height: df.DfSpace.lg),
                      directionalHint,
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _DirIcon extends StatelessWidget {
  const _DirIcon({required this.icon, required this.active});

  final IconData icon;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: active ? df.DfColors.accent : df.DfColors.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: active ? Colors.white : df.DfColors.textMuted, size: 26),
    );
  }
}
