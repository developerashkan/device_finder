// Home: header with Demo/Live switch, the orbitable 3D radar, and the
// nearby-device list. Handles scanning, permission and error states.
import 'package:device_finder/device_finder.dart' as df;
import 'package:flutter/material.dart';

import '../finder_controller.dart';
import 'components.dart';
import 'locate_screen.dart';
import 'palette.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller, this.radarInitialTime});
  final FinderController controller;

  /// Screenshot hook: start the radar animation at this moment.
  final double? radarInitialTime;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _selected;
  bool _hintVisible = true;

  FinderController get _c => widget.controller;

  void _open(String id) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: Motion.reduced(context) ? Duration.zero : const Duration(milliseconds: 380),
        reverseTransitionDuration: Motion.reduced(context) ? Duration.zero : Motion.exit,
        pageBuilder: (_, __, ___) => LocateScreen(controller: _c, deviceId: id),
        transitionsBuilder: (_, anim, __, child) {
          final a = CurvedAnimation(parent: anim, curve: Motion.curve, reverseCurve: Curves.easeInCubic);
          return FadeTransition(
            opacity: a,
            child: SlideTransition(position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(a), child: child),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: SafeArea(
          child: ListenableBuilder(
            listenable: Listenable.merge([_c, _c.tracker.stateNotifier.toFlutter]),
            builder: (context, _) {
              final states =
                  _c.tracker.states.toList()
                    ..sort((a, b) => (a.estimate?.meters ?? double.infinity).compareTo(b.estimate?.meters ?? double.infinity));
              final targets = df.RadarTarget.fromStates(states);
              return LayoutBuilder(
                builder: (context, box) {
                  final wide = box.maxWidth >= 760;
                  final header = _Header(controller: _c, count: targets.length);
                  final radar = _RadarPanel(
                    palette: p,
                    targets: targets,
                    selected: _selected,
                    status: _c.status,
                    hintVisible: _hintVisible,
                    initialTime: widget.radarInitialTime,
                    onInteract: () {
                      if (_hintVisible) setState(() => _hintVisible = false);
                    },
                    onTap: (id) => setState(() => _selected = _selected == id ? null : id),
                  );
                  final list = _DeviceList(controller: _c, states: states, selected: _selected, onOpen: _open);
                  if (wide) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                      child: Column(
                        children: [
                          header,
                          const SizedBox(height: 16),
                          Expanded(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(flex: 6, child: Padding(padding: const EdgeInsets.only(bottom: 24), child: radar)),
                                const SizedBox(width: 24),
                                Expanded(flex: 5, child: list),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  final radarHeight = (box.maxHeight * 0.46).clamp(260.0, box.maxWidth * 1.05);
                  return Column(
                    children: [
                      Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 0), child: header),
                      const SizedBox(height: 8),
                      SizedBox(height: radarHeight, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: radar)),
                      Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: list)),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller, required this.count});
  final FinderController controller;
  final int count;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final c = controller;
    final sub = switch (c.status) {
      SourceStatus.starting => 'Starting Bluetooth…',
      SourceStatus.needsPermission => 'Bluetooth needs permission',
      SourceStatus.unavailable => 'Bluetooth unavailable',
      SourceStatus.running =>
        c.mode == SourceMode.demo ? '$count nearby' : (count == 0 ? 'Scanning for devices…' : '$count nearby'),
    };
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: LinearGradient(colors: [p.accent, p.radar.accentSecondary], begin: Alignment.topLeft, end: Alignment.bottomRight),
            boxShadow: [BoxShadow(color: p.accent.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 6))],
          ),
          child: const Icon(Icons.radar_rounded, color: Colors.white, size: 26),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Finder', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.6, color: p.text, height: 1.1)),
              const SizedBox(height: 2),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: p.muted, height: 1.3)),
            ],
          ),
        ),
        SegmentedSwitch(
          labels: const ['Demo', 'Live'],
          index: c.mode == SourceMode.demo ? 0 : 1,
          onChanged: (i) => c.setMode(i == 0 ? SourceMode.demo : SourceMode.live),
        ),
      ],
    );
  }
}

class _RadarPanel extends StatelessWidget {
  const _RadarPanel({
    required this.palette,
    required this.targets,
    required this.selected,
    required this.status,
    required this.hintVisible,
    required this.onInteract,
    required this.onTap,
    this.initialTime,
  });

  final Palette palette;
  final List<df.RadarTarget> targets;
  final String? selected;
  final SourceStatus status;
  final bool hintVisible;
  final VoidCallback onInteract;
  final ValueChanged<String> onTap;
  final double? initialTime;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final live = targets.where((t) => !t.stale).length;
    return Listener(
      onPointerDown: (_) => onInteract(),
      child: Stack(
        children: [
          Positioned.fill(
            child: df.Radar3DView(
              targets: targets,
              selectedId: selected,
              onTargetTap: onTap,
              theme: p.radar,
              initialTime: initialTime,
              paintBackground: false,
            ),
          ),
          Positioned(
            left: 8,
            top: 4,
            child: PulseBadge(
              label: status == SourceStatus.running ? 'SCANNING · $live' : 'STANDBY',
              color: status == SourceStatus.running ? p.ok : p.warn,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 6,
            child: IgnorePointer(
              child: Center(
                child: AnimatedOpacity(
                  opacity: hintVisible ? 1 : 0,
                  duration: Motion.exit,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: p.dark ? const Color(0xB30A1322) : const Color(0xE6FFFFFF),
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(color: p.border),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.threed_rotation_rounded, size: 16, color: p.textSecondary),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Drag to orbit · tap a device',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({required this.controller, required this.states, required this.selected, required this.onOpen});
  final FinderController controller;
  final List<df.TrackedDeviceState> states;
  final String? selected;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final c = controller;

    if (c.status == SourceStatus.needsPermission || c.status == SourceStatus.unavailable) {
      return _Problem(controller: c);
    }

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
      child: Row(
        children: [
          Text('Nearby', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: p.text)),
          const SizedBox(width: 8),
          Text('closest first', style: TextStyle(fontSize: 13, color: p.muted)),
        ],
      ),
    );

    if (states.isEmpty) {
      return ListView(
        padding: EdgeInsets.zero,
        children: [header, for (var i = 0; i < 3; i++) const Padding(padding: EdgeInsets.only(bottom: 10), child: _SkeletonTile())],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: states.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) return header;
        final s = states[i - 1];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: EnterAnimation(
            key: ValueKey('enter-${s.info.id}'),
            index: i - 1,
            child: DeviceTile(state: s, now: c.now, selected: s.info.id == selected, onTap: () => onOpen(s.info.id)),
          ),
        );
      },
    );
  }
}

class DeviceTile extends StatelessWidget {
  const DeviceTile({super.key, required this.state, required this.now, required this.onTap, this.selected = false});
  final df.TrackedDeviceState state;
  final DateTime now;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final s = state;
    final e = s.estimate;
    final color = p.deviceColor(s.info.id);
    final stale = e?.isStale ?? true;
    final name = s.info.displayName ?? s.info.name ?? s.info.id;
    final located = s.fix != null && s.fix!.status == df.FixStatus.fresh;
    final ago = s.lastSeen == null ? null : now.difference(s.lastSeen!).inSeconds;
    final trend = s.trend;

    final distanceLabel = e == null ? 'Searching' : '${formatMeters(e.meters)} m';
    return Opacity(
      opacity: stale ? 0.62 : 1,
      child: Pressable(
        onTap: onTap,
        semanticLabel:
            '$name, ${e == null ? 'searching' : '${formatMeters(e.meters)} meters'}${stale ? ', signal lost' : ''}. Opens locate view.',
        child: GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          borderColor: selected ? color.withValues(alpha: 0.8) : null,
          child: Row(
            children: [
              Hero(
                tag: 'avatar-${s.info.id}',
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [Color.lerp(color, Colors.white, 0.15)!, Color.lerp(color, Colors.black, 0.25)!],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: stale ? null : [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 14)],
                  ),
                  child: Icon(iconForKind(s.info.kind), color: Colors.white, size: 22),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: p.text, height: 1.25),
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        TagChip(label: labelForKind(s.info.kind), color: p.textSecondary),
                        if (stale && ago != null)
                          TagChip(label: 'Lost · ${ago}s', color: p.danger, icon: Icons.portable_wifi_off_rounded)
                        else
                          TagChip(
                            label: located ? 'Located' : 'Range only',
                            color: located ? p.ok : p.accent,
                            icon: located ? Icons.my_location_rounded : Icons.radio_button_unchecked_rounded,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!stale && trend == df.ProximityTrend.closing)
                        Icon(Icons.arrow_downward_rounded, size: 16, color: p.ok, semanticLabel: 'getting closer')
                      else if (!stale && trend == df.ProximityTrend.receding)
                        Icon(Icons.arrow_upward_rounded, size: 16, color: p.danger, semanticLabel: 'moving away'),
                      const SizedBox(width: 2),
                      Text(
                        distanceLabel,
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          color: p.text,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SignalBars(strength: e == null || stale ? 0 : df.strengthFromRssi(e.rssiDb), color: color),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SkeletonTile extends StatefulWidget {
  const _SkeletonTile();

  @override
  State<_SkeletonTile> createState() => _SkeletonTileState();
}

class _SkeletonTileState extends State<_SkeletonTile> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!Motion.reduced(context) && !_c.isAnimating) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget bar(double w, double h) =>
        Container(width: w, height: h, decoration: BoxDecoration(color: p.surfaceStrong, borderRadius: BorderRadius.circular(6)));
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => Opacity(opacity: 0.55 + 0.45 * (1 - (2 * _c.value - 1).abs()), child: child),
      child: GlassCard(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(width: 46, height: 46, decoration: BoxDecoration(shape: BoxShape.circle, color: p.surfaceStrong)),
            const SizedBox(width: 14),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [bar(130, 14), const SizedBox(height: 8), bar(80, 12)]),
            const Spacer(),
            bar(52, 18),
          ],
        ),
      ),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({required this.controller});
  final FinderController controller;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final perm = controller.status == SourceStatus.needsPermission;
    return ListView(
      padding: const EdgeInsets.only(top: 8),
      children: [
        GlassCard(
          borderColor: p.warn.withValues(alpha: 0.5),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(perm ? Icons.bluetooth_disabled_rounded : Icons.error_outline_rounded, color: p.warn, size: 28),
              const SizedBox(height: 10),
              Text(
                perm ? 'Bluetooth needs your OK' : 'Live scanning unavailable',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: p.text),
              ),
              const SizedBox(height: 6),
              Text(
                controller.message ?? 'Something went wrong while starting Bluetooth.',
                style: TextStyle(fontSize: 15, height: 1.45, color: p.textSecondary),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: controller.retry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Try again'),
                    style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  ),
                  OutlinedButton(
                    onPressed: () => controller.setMode(SourceMode.demo),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    child: const Text('Use demo room'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
