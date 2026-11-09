/// `dart:io` JSON file store (mobile and desktop).
library;

import 'dart:convert';
import 'dart:io';

import '../engine/model.dart';
import 'profile_store_base.dart';

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
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map) return;
      decoded.forEach((k, v) {
        // One bad entry must not discard the others.
        try {
          if (k is String && v is Map) {
            super.save(k, CalibrationProfile.fromJson(v.cast<String, Object?>())); // cache only
          }
        } catch (_) {}
      });
    } catch (_) {
      // Unreadable/corrupt store: start fresh (never crash the app on load).
    }
  }

  Future<void> _pending = Future<void>.value();

  @override
  Future<void> save(String deviceId, CalibrationProfile profile) {
    // Serialize writes: concurrent saves must not race on the temp file.
    final next = _pending.then((_) async {
      await super.save(deviceId, profile);
      await _flush();
    });
    _pending = next.catchError((Object _) {});
    return next;
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
