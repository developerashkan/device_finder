/// Device list — groups discovered devices by their broadcast name
/// (bypassing rotating MAC addresses).
///
/// Each entry shows name/kind, distance + RSSI, a mini signal bar, and a
/// staleness badge. Selection reports the chosen device id.
library;

import 'package:flutter/material.dart';

import '../../design/design.dart';
import '../../engine/model.dart';
import '../signal_meter/signal_meter.dart';

class DeviceList extends StatelessWidget {
  const DeviceList({
    super.key,
    required this.states,
    this.onSelect,
    this.selectedId,
    this.emptyMessage = 'Scanning for devices…',
  });

  /// Live tracking states, one per grouped device.
  final List<TrackedDeviceState> states;
  final ValueChanged<String>? onSelect;
  final String? selectedId;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    // Group by unique ID to ensure every physical device is shown individually.
    final grouped = <String, List<TrackedDeviceState>>{};
    for (final s in states) {
      final key = s.info.id;
      grouped.putIfAbsent(key, () => []).add(s);
    }

    if (grouped.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(DfSpace.xl),
        child: Center(
          child: Text(emptyMessage, style: DfType.body),
        ),
      );
    }

    final entries = grouped.entries.toList()
      ..sort((a, b) => (a.value.first.estimate?.meters ?? double.infinity)
          .compareTo(b.value.first.estimate?.meters ?? double.infinity));

    return ListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(DfSpace.md), // 12 px on all sides
      children: [
        for (final e in entries)
          _DeviceTile(
            key: ValueKey('group-${e.key}'),
            name: e.key,
            states: e.value,
            selected: e.key == selectedId,
            onTap: onSelect == null ? null : () => onSelect!(e.value.first.info.id),
          ),
      ],
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({super.key, required this.name, required this.states, this.selected = false, this.onTap});

  final String name;
  final List<TrackedDeviceState> states;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final primary = states.first;
    final estimate = primary.estimate;
    final displayName = primary.info.displayName ?? primary.info.name ?? primary.info.id;

    return Container(
      margin: const EdgeInsets.all(DfSpace.md), // 12 px on all sides
      child: Material(
        color: selected ? DfColors.surfaceHigh : DfColors.surface,
        borderRadius: BorderRadius.circular(DfRadius.medium),
        child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DfRadius.medium),
        child: Padding(
          padding: const EdgeInsets.all(DfSpace.md),
          child: Row(
            children: [
              // Device icon.
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: DfColors.accentFaint,
                  borderRadius: BorderRadius.circular(DfRadius.small),
                ),
                child: Icon(
                  primary.info.kind == 'beacon'
                      ? Icons.radar
                      : primary.info.kind == 'tag'
                          ? Icons.sell_outlined
                          : primary.info.kind == 'headphones'
                              ? Icons.headphones
                              : Icons.bluetooth,
                  color: DfColors.accent,
                  size: 22,
                ),
              ),
              const SizedBox(width: DfSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(displayName, style: DfType.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 6),
                        // Kind chip: makes it clear beacons/tags are devices.
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: DfColors.accentFaint,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            primary.info.kind ?? 'Device',
                            style: const TextStyle(fontSize: 9, color: DfColors.accent, letterSpacing: 0.4),
                          ),
                        ),
                        const SizedBox(width: DfSpace.sm),
                        if (estimate?.isStale ?? false)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: DfColors.danger.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('STALE', style: TextStyle(fontSize: 9, color: DfColors.danger, letterSpacing: 0.5)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          estimate == null ? 'no signal' : '${estimate.meters.toStringAsFixed(1)} m',
                          style: DfType.valueSmall,
                        ),
                        const SizedBox(width: DfSpace.md),
                        Expanded(
                          child: SignalMeter(estimate: estimate, rssiOverride: estimate?.rssiDb, compact: true),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: DfColors.textMuted, size: 20),
            ],
          ),
        ),
        ),
      ),
    );
  }
}
