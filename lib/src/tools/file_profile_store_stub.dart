/// Web stub: there is no file system, so use [MemoryProfileStore] (or your
/// own [ProfileStore] over IndexedDB / shared_preferences) instead.
library;

import 'profile_store_base.dart';

class FileProfileStore extends MemoryProfileStore {
  FileProfileStore({required Object directory, this.fileName = 'device_finder_profiles.json'}) {
    throw UnsupportedError('FileProfileStore needs dart:io; use MemoryProfileStore on the web.');
  }

  final String fileName;
}
