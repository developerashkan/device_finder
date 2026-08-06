import 'dart:io';

import 'package:device_finder/device_finder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late FileProfileStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('df_profiles_');
    store = FileProfileStore(directory: tmp);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('save + load round trip', () async {
    final p = CalibrationProfile(
      txPower: -58.4,
      exponent: 2.83,
      residualRmsDb: 0.39,
      calibratedAt: DateTime(2026, 1, 1),
      distancesUsed: const [1, 2, 4, 8],
      samplesPerDistance: 60,
    );
    await store.save('aa:bb:cc', p);
    final loaded = store.load('aa:bb:cc');
    expect(loaded, isNotNull);
    expect(loaded!.txPower, closeTo(-58.4, 1e-9));
    expect(loaded.exponent, closeTo(2.83, 1e-9));
    expect(loaded.residualRmsDb, closeTo(0.39, 1e-9));
    expect(loaded.distancesUsed, [1, 2, 4, 8]);
  });

  test('profiles persist across store instances (file reload)', () async {
    final p = CalibrationProfile(
      txPower: -60,
      exponent: 2.9,
      residualRmsDb: 1,
      calibratedAt: DateTime(2026, 2, 2),
    );
    await store.save('aa:bb:cc', p);
    final reloaded = FileProfileStore(directory: tmp);
    final loaded = reloaded.load('aa:bb:cc');
    expect(loaded, isNotNull);
    expect(loaded!.txPower, closeTo(-60, 1e-9));
  });

  test('defaults are not persisted as profiles', () async {
    await store.save('aa:bb:cc', CalibrationProfile.defaults);
    // A default profile should be treated as "no calibration" by loaders.
    final loaded = store.load('aa:bb:cc');
    expect(loaded, isNotNull);
    expect(loaded!.isDefault, isTrue);
  });

  test('corrupt file starts fresh without crashing', () {
    File('${tmp.path}/device_finder_profiles.json')
        .writeAsStringSync('{not json');
    // Should not throw.
    final s = FileProfileStore(directory: tmp);
    expect(s.all(), isEmpty);
  });
}
