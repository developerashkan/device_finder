/// Offline calibration profiles — device-specific (TxPower, n) fits.
///
/// Fully offline, loads instantly on device detection. The engine consumes
/// these through a `profileResolver`; this package provides a JSON file store
/// over `dart:io` (atomic write via temp + rename). Hosts may inject their
/// own store (SQLite, shared_preferences, etc.) through the same interface.
library;

import '../engine/model.dart';

/// Interface for calibration profile persistence.
abstract class ProfileStore {
  /// Load a profile for a device, or null when none exists.
  CalibrationProfile? load(String deviceId);

  /// Save (overwrite) a profile for a device.
  Future<void> save(String deviceId, CalibrationProfile profile);

  /// All known profiles.
  Map<String, CalibrationProfile> all();
}

/// In-memory store — profiles are cached after first load and shared across
/// the engine; [all] reflects the cache, so lookups are instant.
class MemoryProfileStore implements ProfileStore {
  final Map<String, CalibrationProfile> _cache = {};

  @override
  CalibrationProfile? load(String deviceId) => _cache[deviceId];

  @override
  Future<void> save(String deviceId, CalibrationProfile profile) async {
    _cache[deviceId] = profile;
  }

  @override
  Map<String, CalibrationProfile> all() => Map.unmodifiable(_cache);
}
