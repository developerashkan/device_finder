/// Signal strength meter — a premium segmented bar with a moving needle,
/// tabular-figure readouts, and a staleness state.
///
/// Repaints via the shared scene Listenable; the widget never rebuilds during
/// live updates.
library;

import 'package:flutter/material.dart';

import '../../design/design.dart';
import '../../engine/model.dart';

/// Converts RSSI (dBm) to a normalized 0..1 strength.
double strengthFromRssi(double rssi) => ((rssi + 100) / 60).clamp(0.0, 1.0);

class SignalMeter extends StatelessWidget {
  const SignalMeter({
    super.key,
    this.estimate,
    this.repaint,
    this.rssiOverride,
    this.compact = false,
  });

  final DistanceEstimate? estimate;
  final Listenable? repaint;
  final double? rssiOverride;

  /// When true, renders a single-line compact bar (no labels/readouts) —
  /// used inside list tiles with a bounded height.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final rssi = rssiOverride ?? estimate?.rssiDb;
    final s = rssi == null ? 0.0 : strengthFromRssi(rssi);
    final stale = estimate?.isStale ?? false;
    final color = stale
        ? DfColors.textMuted
        : s > 0.66
            ? DfColors.ok
            : s > 0.33
                ? DfColors.accent
                : DfColors.warning;

    if (compact) {
      // Single-row segmented bar that fits any bounded height.
      return SizedBox(
        height: 8,
        child: Row(
          children: [
            for (var i = 0; i < 16; i++) ...[
              Expanded(
                child: Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: (i + 1) / 16 <= s ? color.withValues(alpha: 0.9) : DfColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              if (i < 15) const SizedBox(width: 2),
            ],
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(stale ? 'NO SIGNAL' : 'SIGNAL', style: DfType.label),
            if (rssi != null)
              Text(
                '${rssi.toStringAsFixed(0)} dBm',
                style: DfType.valueSmall.copyWith(color: color),
              ),
          ],
        ),
        const SizedBox(height: DfSpace.sm),
        // Segmented strength bar (16 segments).
        SizedBox(
          height: 10,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: 16,
            separatorBuilder: (_, __) => const SizedBox(width: 3),
            itemBuilder: (context, i) {
              final on = (i + 1) / 16 <= s;
              return Container(
                width: 12,
                decoration: BoxDecoration(
                  color: on ? color.withValues(alpha: 0.9) : DfColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(3),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: DfSpace.sm),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('−100', style: DfType.valueSmall.copyWith(color: DfColors.textMuted, fontSize: 10)),
            if (estimate != null)
              Text(
                '${estimate!.meters.toStringAsFixed(1)} m',
                style: DfType.value,
              ),
            Text('−40', style: DfType.valueSmall.copyWith(color: DfColors.textMuted, fontSize: 10)),
          ],
        ),
      ],
    );
  }
}
