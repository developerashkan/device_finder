# Finder — device_finder example

A complete device-finding app built on `device_finder`:

- **Demo** (default): a simulated room with three hubs. AirPods and the watch
  are heard by the hubs, so they are *located* (trilaterated) with a
  confidence ellipse; the tag and buds are heard only by the phone, so they
  ride their range ring ("range only"); the desk beacon drops out now and then
  to show the *lost* state. No Bluetooth needed.
- **Live**: scans real BLE devices through `device_finder_ble`, with clear
  permission / unavailable states and a one-tap way back to the demo.

Tap a device for the locate view: big distance readout, proximity meter,
signal / accuracy / source / battery, direction (when located) and Geiger
haptics. Drag the radar to orbit, double-tap to reset.

```bash
flutter run                 # any platform; Live mode needs Bluetooth
flutter test                # app + simulator tests
flutter test test/screenshots_test.dart --dart-define=CAPTURE=true  # README images
```

Platform setup for Live mode (Android permissions, iOS/macOS usage strings,
macOS Bluetooth entitlement) is already configured in this folder.
