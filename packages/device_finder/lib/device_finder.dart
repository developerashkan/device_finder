/// `device_finder` — fully offline Bluetooth device tracking for Flutter.
///
/// A pure-Dart RSSI signal engine (Kalman filter, trilateration, mirror
/// resolution, calibration) fused with a premium, 60fps CustomPaint radar UI.
/// Pair with [`device_finder_ble`] for BLE capture, or feed the engine any
/// [RssiSample] stream from your own driver.
library;

export 'src/engine/engine.dart';
export 'src/engine/model.dart';
export 'src/engine/direction.dart';
export 'src/widgets/widgets.dart';
export 'src/design/design.dart';
export 'src/tools/haptics.dart';
export 'src/tools/hardware.dart';
export 'src/tools/profile_store.dart';
