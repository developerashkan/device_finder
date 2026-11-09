// Runs on the VM and in a browser:
//   flutter test --platform chrome test/cross_platform_test.dart
// Radar colors and orbit phases derive from these hashes, so they must be
// bit-identical everywhere. Golden values computed with exact big-integer
// arithmetic (independent of Dart).
import 'package:device_finder/device_finder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mul32 is exact modulo 2^32', () {
    expect(RadarTarget.mul32(0xffffffff, 0xffffffff), 0x00000001);
    expect(RadarTarget.mul32(0x811c9dc5, 0x01000193), 0x050c5d1f);
    expect(RadarTarget.mul32(0x075bcd15, 0x3ade68b1), 0xfbff5385);
    expect(RadarTarget.mul32(0xdeadbeef, 0x846ca68b), 0x5af9a5c5);
  });

  test('stableHash golden values', () {
    int h(String id) => RadarTarget(id: id, label: '', meters: 1).stableHash;
    expect(h('sim-airpods'), 0x81d34516);
    expect(h('sim-watch'), 0x0d5e0b87);
    expect(h('sim-keys'), 0x82cd8d10);
    expect(h('sim-buds'), 0x9e29cdf3);
    expect(h('sim-beacon'), 0x19dabd5d);
    expect(h('AA:BB:CC:DD:EE:FF'), 0xbfb9091b);
    expect(h(''), 0x74141c20);
  });
}
