/// The flutter_blue_plus driver for `device_finder`.
///
/// Emits engine-ready [RssiSample]s from:
/// - passively observed advertisements (`continuousUpdates` scan),
/// - connected-link RSSI (`readRssi` / `events.onReadRssi`),
/// and handles platform permissions (Android 12+ BLUETOOTH_SCAN/CONNECT,
/// legacy ACCESS_FINE_LOCATION, iOS NSBluetoothAlwaysUsageDescription).
library;

import 'dart:async';

import 'package:device_finder/device_finder.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// GATT Battery Service (0x180F) — Battery Level characteristic (0x2A19).
Guid kBatteryServiceUuid() => Guid('0000180f-0000-1000-8000-00805f9b34fb');
Guid kBatteryLevelUuid() => Guid('00002a19-0000-1000-8000-00805f9b34fb');

/// Called when the user taps "enable BLE" in the example app.
class BleCapabilities {
  const BleCapabilities({required this.supportsAdvertising, required this.supportsConnectedLink});
  final bool supportsAdvertising;
  final bool supportsConnectedLink;
}

class BleDriver {
  BleDriver({this.scanTimeout = const Duration(seconds: 30)});

  final Duration scanTimeout;

  final StreamController<RssiSample> _samples = StreamController.broadcast();
  final StreamController<DeviceInfo> _info = StreamController.broadcast();
  final Map<String, BluetoothDevice> _devices = {};

  /// Engine-ready sample stream (advertising + connected link).
  Stream<RssiSample> get samples => _samples.stream;

  /// Stream of discovered device metadata.
  Stream<DeviceInfo> get info => _info.stream;

  /// True once `start` has been called (for permission UI gating).
  bool started = false;

  /// Requests platform permissions; returns true when scanning is possible.
  ///
  /// In flutter_blue_plus 2.x the Android plugin auto-requests
  /// BLUETOOTH_SCAN / BLUETOOTH_CONNECT (or ACCESS_FINE_LOCATION on older
  /// Android) at first use; iOS prompts via NSBluetoothAlwaysUsageDescription.
  /// Here we only wait for the adapter to be on and ready.
  Future<bool> ensurePermissions() async {
    if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on) return true;
    // Wait (up to ~10 s) for the user to enable Bluetooth.
    final state = await FlutterBluePlus.adapterState
        .where((s) => s == BluetoothAdapterState.on)
        .timeout(const Duration(seconds: 10), onTimeout: (EventSink<BluetoothAdapterState> _) {})
        .first;
    return state == BluetoothAdapterState.on;
  }

  /// Starts a continuous (per-packet) scan and pipes advertisements into the
  /// engine. On each packet the [txPower] (AD 0x0A) is forwarded when present.
  Future<void> startScan() async {
    started = true;
    FlutterBluePlus.onScanResults.listen((results) {
      if (results.isEmpty) return;
      final now = DateTime.now();
      for (final r in results) {
        final id = r.device.remoteId.str;
        if (id.isEmpty) continue;

        _devices[id] = r.device;
        
        final advName = r.advertisementData.advName.trim();
        final platformName = r.device.platformName.trim();
        
        String name;
        if (advName.isNotEmpty) {
          name = advName;
        } else if (platformName.isNotEmpty) {
          name = platformName;
        } else {
          // Robust fallback name with MAC suffix.
          name = 'Device :${id.length > 5 ? id.substring(id.length - 5) : id}';
        }
        
        _info.add(DeviceInfo(
          id: id,
          name: name,
          kind: _guessKind(r),
        ));

        _samples.add(RssiSample(
          deviceId: id,
          source: RssiSource.advertising,
          dbm: r.rssi.toDouble(),
          at: now,
          txPower: r.advertisementData.txPowerLevel?.toDouble(),
        ));
      }
    });
    await FlutterBluePlus.startScan(
      continuousUpdates: true,
      androidScanMode: AndroidScanMode.lowLatency,
      removeIfGone: null,
    );
  }

  /// Connects (LE transport) and polls connected-link RSSI at [interval].
  Future<void> connectAndPollRssi(String deviceId, {Duration interval = const Duration(milliseconds: 300)}) async {
    final d = _devices[deviceId];
    if (d == null) return;
    await d.connect(
      timeout: const Duration(seconds: 10),
      autoConnect: false,
      // Nonprofit/personal use of flutter_blue_plus; commercial users must
      // obtain a paid License.commercial and pass it here.
      license: License.nonprofit,
    );
    // Poll readRssi; also stream the event-driven onReadRssi.
    FlutterBluePlus.events.onReadRssi.listen((e) {
      if (e.device.remoteId.str != deviceId || e.error != null) return;
      _samples.add(RssiSample(
        deviceId: deviceId,
        source: RssiSource.connectedLink,
        dbm: e.rssi.toDouble(),
        at: DateTime.now(),
      ));
    });
    Timer.periodic(interval, (_) async {
      try {
        await d.readRssi();
      } catch (_) {
        // Disconnected mid-poll — ignore.
      }
    });
  }

  /// Reads the device battery (0-100) via the GATT Battery Service, or
  /// returns null when the device doesn't expose it.
  Future<int?> readBatteryLevel(String deviceId) async {
    final d = _devices[deviceId];
    if (d == null) return null;
    try {
      final service = await d.discoverServices();
      for (final s in service) {
        if (s.uuid != kBatteryServiceUuid()) continue;
        for (final c in s.characteristics) {
          if (c.uuid == kBatteryLevelUuid() && c.properties.read) {
            final v = await c.read();
            if (v.isNotEmpty) return v.first;
          }
        }
      }
    } catch (_) {
      // Battery is optional; never fail tracking over it.
    }
    return null;
  }

  /// Stops scanning and disconnects.
  Future<void> stop() async {
    if (started) {
      await FlutterBluePlus.stopScan();
    }
    for (final d in _devices.values) {
      try {
        await d.disconnect();
      } catch (_) {}
    }
    _devices.clear();
    started = false;
  }

  String _guessKind(ScanResult r) {
    final name = (r.advertisementData.advName.isNotEmpty 
            ? r.advertisementData.advName 
            : r.device.platformName).toLowerCase();
    
    if (name.contains('airtag') || name.contains('tile')) return 'tag';
    if (name.contains('beacon')) return 'beacon';
    if (name.contains('headphone') || name.contains('buds') || name.contains('airpods')) return 'headphones';
    
    // Check service UUIDs for common types.
    for (final uuid in r.advertisementData.serviceUuids) {
      final s = uuid.toString().toLowerCase();
      if (s.contains('feaa')) return 'beacon'; // Eddystone
      if (s.contains('180f')) return 'battery';
    }
    
    return 'other';
  }

  void dispose() {
    _samples.close();
    _info.close();
  }
}
