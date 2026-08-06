/// Offline calibration profiles — device-specific (TxPower, n) fits.
///
/// Fully offline, loads instantly on device detection. The engine consumes
/// these through a `profileResolver`; this package provides a JSON file store
/// over `dart:io` (atomic write via temp + rename). Hosts may inject their
/// own store (SQLite, shared_preferences, etc.) through the same interface.
library;

import 'dart:convert';
import 'dart:io';

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

/// JSON file store at [directory]/device_finder_profiles.json.
///
/// Writes are atomic (temp file + rename) so a crash mid-write never corrupts
/// the store.
class FileProfileStore extends MemoryProfileStore {
  FileProfileStore({required this.directory, this.fileName = 'device_finder_profiles.json'}) {
    _load();
  }

  final Directory directory;
  final String fileName;

  File get _file => File('${directory.path}/$fileName');

  void _load() {
    if (!_file.existsSync()) return;
    try {
      final map = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
      map.forEach((k, v) {
        final p = CalibrationProfile.fromJson((v as Map).cast<String, dynamic>());
        super.save(k, p); // cache only
      });
    } catch (_) {
      // Corrupt store: start fresh (never crash the app on load).
    }
  }

  @override
  Future<void> save(String deviceId, CalibrationProfile profile) async {
    await super.save(deviceId, profile);
    await _flush();
  }

  Future<void> _flush() async {
    try {
      final dir = directory;
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final payload = jsonEncode(all());
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(payload, flush: true);
      await tmp.rename(_file.path);
    } catch (_) {
      // Best-effort persistence; profiles still work in memory.
    }
  }
}
