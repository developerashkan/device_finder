# device_finder_ble

Optional BLE capture driver for [`device_finder`](https://pub.dev/packages/device_finder).
Bridges [`flutter_blue_plus`](https://pub.dev/packages/flutter_blue_plus)
advertisement and connected-link RSSI streams into the pure-Dart engine, with
platform permission handling.

## Usage

```dart
final driver = BleDriver();
await driver.ensurePermissions();
driver.samples.listen(tracker.pushSample);
await driver.startScan(); // continuous, per-packet
await driver.connectAndPollRssi(deviceId); // prefers connected-link RSSI
```

See the `example/` folder for a complete end-to-end finder app
(permissions → scan → select → calibrate → radar).

## Permissions

Add the same permissions as `device_finder` (see its README): Android
`BLUETOOTH_SCAN`/`BLUETOOTH_CONNECT` (or legacy `ACCESS_FINE_LOCATION`),
iOS `NSBluetoothAlwaysUsageDescription`.

> Note: `flutter_blue_plus` is commercially licensed; free for personal,
> nonprofit, and educational use. `device_finder` (the core package) has no
> such dependency.
