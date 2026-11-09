// Shared building blocks: background, glass card, pressable, entrance
// animation, segmented switch, status badge, signal bars.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'palette.dart';

/// Full-bleed gradient backdrop with a soft accent glow.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [p.bgTop, p.bgBottom]),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.55),
            radius: 1.0,
            colors: [p.accent.withValues(alpha: p.dark ? 0.10 : 0.07), p.accent.withValues(alpha: 0)],
          ),
        ),
        child: child,
      ),
    );
  }
}

/// Rounded, softly translucent card with a hairline border.
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.borderColor, this.radius = 20});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? borderColor;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedContainer(
      duration: Motion.enter,
      curve: Motion.curve,
      padding: padding,
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor ?? p.border, width: borderColor == null ? 1 : 1.5),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          // Light cards are opaque so their drop shadow never shows through.
          colors: p.dark
              ? [Colors.white.withValues(alpha: 0.06), Colors.white.withValues(alpha: 0.015)]
              : const [Colors.white, Color(0xFFF6F9FD)],
        ),
      ),
      child: child,
    );
  }
}

/// Press feedback (scale 0.97 within 120 ms) + ripple, ≥ 48 dp target.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, required this.onTap, this.semanticLabel, this.radius = 20});
  final Widget child;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final double radius;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration: Motion.reduced(context) ? Duration.zero : Motion.press,
        curve: Curves.easeOut,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(widget.radius),
            onTap: widget.onTap,
            onHighlightChanged: (v) => setState(() => _down = v),
            child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 48), child: widget.child),
          ),
        ),
      ),
    );
  }
}

/// Fade + rise entrance with a per-index stagger (no timers: the delay is an
/// Interval inside one animation, so tests never see pending timers).
class EnterAnimation extends StatefulWidget {
  const EnterAnimation({super.key, required this.child, this.index = 0});
  final Widget child;
  final int index;

  @override
  State<EnterAnimation> createState() => _EnterAnimationState();
}

class _EnterAnimationState extends State<EnterAnimation> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _a;

  @override
  void initState() {
    super.initState();
    final delay = Motion.stagger.inMilliseconds * math.min(widget.index, 8).toInt();
    final total = delay + Motion.enter.inMilliseconds;
    _c = AnimationController(vsync: this, duration: Duration(milliseconds: total));
    _a = CurvedAnimation(parent: _c, curve: Interval(delay / total, 1, curve: Motion.curve));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      _c.value = 1;
    } else if (_c.value == 0 && !_c.isAnimating) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _a,
      child: widget.child,
      builder:
          (context, child) => Opacity(opacity: _a.value, child: Transform.translate(offset: Offset(0, 14 * (1 - _a.value)), child: child)),
    );
  }
}

/// Two-option segmented switch with a sliding thumb.
class SegmentedSwitch extends StatelessWidget {
  const SegmentedSwitch({super.key, required this.labels, required this.index, required this.onChanged});
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    const h = 44.0, w = 74.0;
    return Container(
      height: h,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: p.surfaceStrong, borderRadius: BorderRadius.circular(h / 2), border: Border.all(color: p.border)),
      child: Stack(
        children: [
          AnimatedPositioned(
            duration: Motion.reduced(context) ? Duration.zero : Motion.enter,
            curve: Motion.curve,
            left: index * w,
            top: 0,
            bottom: 0,
            width: w,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: p.accent,
                borderRadius: BorderRadius.circular(h / 2),
                boxShadow: [BoxShadow(color: p.accent.withValues(alpha: 0.35), blurRadius: 14)],
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < labels.length; i++)
                Semantics(
                  button: true,
                  selected: i == index,
                  label: '${labels[i]} mode',
                  excludeSemantics: true,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(h / 2),
                    onTap: () => onChanged(i),
                    child: SizedBox(
                      width: w,
                      child: Center(
                        child: AnimatedDefaultTextStyle(
                          duration: Motion.enter,
                          style: DefaultTextStyle.of(context).style.merge(
                            TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: i == index ? (p.dark ? const Color(0xFF04121C) : Colors.white) : p.textSecondary,
                            ),
                          ),
                          child: Text(labels[i]),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Pulsing status dot + label ("SCANNING · 5").
class PulseBadge extends StatefulWidget {
  const PulseBadge({super.key, required this.label, required this.color});
  final String label;
  final Color color;

  @override
  State<PulseBadge> createState() => _PulseBadgeState();
}

class _PulseBadgeState extends State<PulseBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: p.dark ? const Color(0xB30A1322) : const Color(0xE6FFFFFF),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: widget.color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: AnimatedBuilder(animation: _c, builder: (context, _) => CustomPaint(painter: _PulsePainter(widget.color, _c.value))),
          ),
          const SizedBox(width: 8),
          Text(widget.label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: p.text)),
        ],
      ),
    );
  }
}

class _PulsePainter extends CustomPainter {
  _PulsePainter(this.color, this.t);
  final Color color;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    canvas.drawCircle(c, 3 + 4 * t, Paint()..color = color.withValues(alpha: 0.5 * (1 - t)));
    canvas.drawCircle(c, 3.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_PulsePainter old) => old.t != t || old.color != color;
}

/// Four rising bars filled by signal strength (0..1).
class SignalBars extends StatelessWidget {
  const SignalBars({super.key, required this.strength, required this.color});
  final double strength;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final lit = (strength * 4).ceil().clamp(0, 4);
    return Semantics(
      label: 'Signal ${(strength * 100).round()} percent',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 4; i++) ...[
            Container(
              width: 4,
              height: 6.0 + i * 3.5,
              decoration: BoxDecoration(color: i < lit ? color : p.border, borderRadius: BorderRadius.circular(2)),
            ),
            if (i < 3) const SizedBox(width: 2.5),
          ],
        ],
      ),
    );
  }
}

/// Small rounded chip.
class TagChip extends StatelessWidget {
  const TagChip({super.key, required this.label, required this.color, this.icon});
  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(99)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 13, color: color), const SizedBox(width: 4)],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color, height: 1.2),
            ),
          ),
        ],
      ),
    );
  }
}
