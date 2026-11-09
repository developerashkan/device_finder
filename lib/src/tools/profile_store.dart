/// Offline calibration profiles — device-specific (TxPower, n) fits.
///
/// Fully offline, loads instantly on device detection. The engine consumes
/// these through a `profileResolver`. [FileProfileStore] persists to a JSON
/// file via `dart:io` (atomic temp + rename, serialized writes); on the web
/// use [MemoryProfileStore] or inject your own [ProfileStore].
library;

export 'profile_store_base.dart';
export 'file_profile_store_stub.dart' if (dart.library.io) 'file_profile_store_io.dart';
