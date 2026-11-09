// Locate: one device in focus — 3D radar, big distance readout, proximity
// meter, signal stats, direction (when known) and Geiger haptics.
import 'dart:math' as math;

import 'package:device_finder/device_finder.dart' as df;
import 'package:flutter/material.dart';

import '../finder_controller.dart';
import 'components.dart';
import 'palette.dart';

class LocateScreen extends StatefulWidget {
  const LocateScreen({super.key, required this.controller, required this.deviceId, this.radarInitialTime});
  final FinderController controller;
  final String deviceId;
  final double? radarInitialTime;

  @override
  State<LocateScreen> createState() => _LocateScreenState();
}

class _LocateScreenState extends State<LocateScreen> {
  final df.GeigerHaptics _haptics = df.GeigerHaptics();
  bool _hapticsOn = false;

  FinderController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.tracker.stateNotifier.addListener(_feedHaptics);
  }

  void _feedHaptics() {
    if (!_hapticsOn) return;
    final e = _c.tracker.stateOf(widget.deviceId)?.estimate;
    if (e != null && !e.isStale) _haptics.update(e.meters);
  }

  void _toggleHaptics() {
    setState(() => _hapticsOn = !_hapticsOn);
    if (_hapticsOn) {
      _haptics.start();
      _feedHaptics();
    } else {
      _haptics.stop();
    }
  }

  @override
  void dispose() {
    _c.tracker.stateNotifier.removeListener(_feedHaptics);
    _haptics.dispose();
    super.dispose();
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
              final s = _c.tracker.stateOf(widget.deviceId);
              if (s == null) return _Gone(onBack: () => Navigator.of(context).maybePop());
              final target = df.RadarTarget.fromState(s);
              final color = p.deviceColor(s.info.id);
              return LayoutBuilder(
                builder: (context, box) {
                  final wide = box.maxWidth >= 760;
                  final radar = df.Radar3DView(
                    targets: target == null ? const [] : [target],
                    selectedId: s.info.id,
                    theme: p.radar,
                    initialPitchDegrees: 52,
                    paintBackground: false,
                    initialTime: widget.radarInitialTime,
                  );
                  final details = _Details(state: s, color: color, now: _c.now, hubs: _c.hubCount);
                  final top = _TopBar(
                    state: s,
                    color: color,
                    hapticsOn: _hapticsOn,
                    onBack: () => Navigator.of(context).maybePop(),
                    onHaptics: _toggleHaptics,
                  );
                  if (wide) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 24, 0),
                      child: Column(
                        children: [
                          top,
                          Expanded(
                            child: Row(
                              children: [
                                Expanded(child: radar),
                                const SizedBox(width: 24),
                                SizedBox(width: 380, child: SingleChildScrollView(child: details)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return Column(
                    children: [
                      Padding(padding: const EdgeInsets.fromLTRB(8, 4, 16, 0), child: top),
                      SizedBox(height: (box.maxHeight * 0.38).clamp(220.0, 420.0), child: radar),
                      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), child: details)),
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

class _TopBar extends StatelessWidget {
  const _TopBar({required this.state, required this.color, required this.hapticsOn, required this.onBack, required this.onHaptics});
  final df.TrackedDeviceState state;
  final Color color;
  final bool hapticsOn;
  final VoidCallback onBack;
  final VoidCallback onHaptics;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final s = state;
    final name = s.info.displayName ?? s.info.name ?? s.info.id;
    return Row(
      children: [
        IconButton(
          onPressed: onBack,
          tooltip: 'Back',
          icon: Icon(Icons.arrow_back_rounded, color: p.text),
          style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
        const SizedBox(width: 4),
        Hero(
          tag: 'avatar-${s.info.id}',
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [Color.lerp(color, Colors.white, 0.15)!, Color.lerp(color, Colors.black, 0.25)!]),
            ),
            child: Icon(iconForKind(s.info.kind), color: Colors.white, size: 20),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: p.text),
              ),
              Text(labelForKind(s.info.kind), style: TextStyle(fontSize: 13, color: p.muted)),
            ],
          ),
        ),
        Tooltip(
          message: hapticsOn ? 'Turn off Geiger haptics' : 'Turn on Geiger haptics',
          child: IconButton.filledTonal(
            onPressed: onHaptics,
            isSelected: hapticsOn,
            icon: const Icon(Icons.vibration_rounded),
            style: IconButton.styleFrom(
              minimumSize: const Size(48, 48),
              backgroundColor: hapticsOn ? p.accent : p.surfaceStrong,
              foregroundColor: hapticsOn ? (p.dark ? const Color(0xFF04121C) : Colors.white) : p.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.state, required this.color, required this.now, required this.hubs});
  final df.TrackedDeviceState state;
  final Color color;
  final DateTime now;
  final int hubs;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final s = state;
    final e = s.estimate;
    final stale = e?.isStale ?? true;
    final strength = e == null || stale ? 0.0 : df.strengthFromRssi(e.rssiDb);
    final fix = s.fix;
    final located = fix != null && fix.status == df.FixStatus.fresh;
    final ago = s.lastSeen == null ? null : now.difference(s.lastSeen!).inSeconds;

    final (trendText, trendColor, trendIcon) =
        stale
            ? ('Signal lost${ago == null ? '' : ' · ${ago}s ago'}', p.danger, Icons.portable_wifi_off_rounded)
            : switch (s.trend) {
              df.ProximityTrend.closing => ('Getting closer', p.ok, Icons.trending_down_rounded),
              df.ProximityTrend.receding => ('Moving away', p.danger, Icons.trending_up_rounded),
              df.ProximityTrend.stable => ('Holding steady', p.accent, Icons.trending_flat_rounded),
              df.ProximityTrend.unknown => ('Listening…', p.muted, Icons.hearing_rounded),
            };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Big distance readout.
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Semantics(
                liveRegion: true,
                label: e == null ? 'Searching' : '${formatMeters(e.meters)} meters away',
                excludeSemantics: true,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.bottomLeft,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      _AnimatedNumber(
                        value: e?.meters,
                        style: TextStyle(
                          fontSize: 68,
                          height: 1,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -2.5,
                          color: stale ? p.muted : p.text,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text('m', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: p.textSecondary)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: AnimatedSwitcher(
                    duration: Motion.reduced(context) ? Duration.zero : Motion.enter,
                    child: TagChip(key: ValueKey(trendText), label: trendText, color: trendColor, icon: trendIcon),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _ProximityMeter(strength: strength, color: color),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: _Stat(icon: Icons.network_cell_rounded, label: 'Signal', value: e == null ? '—' : '${e.rssiDb.round()} dBm')),
            const SizedBox(width: 10),
            Expanded(
              child: _Stat(
                icon: Icons.blur_circular_rounded,
                label: 'Accuracy',
                value: e == null ? '—' : '± ${formatMeters(e.sigmaMeters)} m',
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _Stat(
                icon: Icons.settings_input_antenna_rounded,
                label: 'Source',
                value: e == null ? '—' : (e.source == df.RssiSource.connectedLink ? 'Linked' : 'Broadcast'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Stat(
                icon: Icons.battery_5_bar_rounded,
                label: 'Battery',
                value: s.info.batteryPercent == null ? 'Unknown' : '${s.info.batteryPercent}%',
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _Direction(fix: located ? fix : null, color: color, hubs: hubs),
      ],
    );
  }
}

/// Smoothly tweens between distance readings (snaps under reduced motion).
class _AnimatedNumber extends StatelessWidget {
  const _AnimatedNumber({required this.value, required this.style});
  final double? value;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final v = value;
    if (v == null) return Text('—', style: style);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: v),
      duration: Motion.reduced(context) ? Duration.zero : Motion.value,
      curve: Motion.curve,
      builder: (context, x, _) => Text(formatMeters(x), style: style),
    );
  }
}

class _ProximityMeter extends StatelessWidget {
  const _ProximityMeter({required this.strength, required this.color});
  final double strength;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Proximity', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: p.text)),
              const Spacer(),
              Text(
                '${(strength * 100).round()}%',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 14,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: strength),
              duration: Motion.reduced(context) ? Duration.zero : Motion.value,
              curve: Motion.curve,
              builder: (context, v, _) => CustomPaint(painter: _MeterPainter(v, color, p)),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('Far', style: TextStyle(fontSize: 12, color: p.muted)),
              const Spacer(),
              Text('Right here', style: TextStyle(fontSize: 12, color: p.muted)),
            ],
          ),
        ],
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  _MeterPainter(this.v, this.color, this.p);
  final double v;
  final Color color;
  final Palette p;

  @override
  void paint(Canvas canvas, Size size) {
    final track = RRect.fromRectAndRadius(Offset(0, size.height / 2 - 4) & Size(size.width, 8), const Radius.circular(4));
    canvas.drawRRect(track, Paint()..color = p.border);
    final w = math.max(8.0, size.width * v.clamp(0.0, 1.0));
    final fill = RRect.fromRectAndRadius(Offset(0, size.height / 2 - 4) & Size(w, 8), const Radius.circular(4));
    canvas.drawRRect(
      fill,
      Paint()..shader = LinearGradient(colors: [color.withValues(alpha: 0.35), color]).createShader(Offset.zero & Size(w, size.height)),
    );
    final knob = Offset(w, size.height / 2);
    canvas.drawCircle(knob, 9, Paint()..color = color.withValues(alpha: 0.25));
    canvas.drawCircle(knob, 6, Paint()..color = color);
    canvas.drawCircle(knob, 2.5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_MeterPainter old) => old.v != v || old.color != color || old.p != p;
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return GlassCard(
      padding: const EdgeInsets.all(14),
      radius: 18,
      child: Row(
        children: [
          Icon(icon, size: 20, color: p.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 12, color: p.muted, height: 1.2)),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Direction extends StatelessWidget {
  const _Direction({required this.fix, required this.color, required this.hubs});
  final df.PositionFix? fix;
  final Color color;
  final int hubs;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final f = fix;
    if (f == null) {
      return GlassCard(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: p.border, width: 2)),
              child: Icon(Icons.explore_off_rounded, color: p.muted),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Direction unknown', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: p.text)),
                  const SizedBox(height: 3),
                  Text(
                    'Only this phone hears it. Walk around: the distance drops as you get closer.',
                    style: TextStyle(fontSize: 13, height: 1.4, color: p.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final bearing = math.atan2(f.x, f.y); // clockwise from forward
    final deg = (bearing * 180 / math.pi).round();
    final a = deg.abs();
    final lr = deg > 0 ? 'right' : 'left';
    final heading =
        a < 15
            ? 'Straight ahead'
            : a < 60
            ? 'Ahead, to the $lr'
            : a < 120
            ? 'On your $lr'
            : 'Behind you';
    final side = a < 15 ? 'dead ahead' : '$a° $lr';
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            height: 52,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: bearing),
              duration: Motion.reduced(context) ? Duration.zero : Motion.value,
              curve: Motion.curve,
              builder: (context, a, _) => CustomPaint(painter: _CompassPainter(a, color, p)),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(heading, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: p.text)),
                const SizedBox(height: 3),
                Text('Located by $hubs hubs · $side', style: TextStyle(fontSize: 13, height: 1.4, color: p.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CompassPainter extends CustomPainter {
  _CompassPainter(this.angle, this.color, this.p);
  final double angle;
  final Color color;
  final Palette p;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    canvas.drawCircle(
      c,
      r - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = p.border,
    );
    canvas.drawCircle(c, r - 6, Paint()..color = color.withValues(alpha: 0.12));
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(angle);
    final arrow =
        Path()
          ..moveTo(0, -r + 7)
          ..lineTo(8, 6)
          ..lineTo(0, 1)
          ..lineTo(-8, 6)
          ..close();
    canvas.drawPath(arrow, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CompassPainter old) => old.angle != angle || old.color != color || old.p != p;
}

class _Gone extends StatelessWidget {
  const _Gone({required this.onBack});
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded, size: 40, color: p.muted),
            const SizedBox(height: 12),
            Text('This device is no longer tracked', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: p.text)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onBack,
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              child: const Text('Back to radar'),
            ),
          ],
        ),
      ),
    );
  }
}
