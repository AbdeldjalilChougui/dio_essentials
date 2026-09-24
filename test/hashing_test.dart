import 'package:dio_essentials/src/hashing.dart';
import 'package:test/test.dart';

void main() {
  test('fnv1a32 matches the published FNV-1a test vectors', () {
    expect(fnv1a32(''), 0x811c9dc5);
    expect(fnv1a32('a'), 0xe40c292c);
    expect(fnv1a32('foobar'), 0xbf9cf968);
  });

  test('djb2 matches the reference definition', () {
    expect(djb2(''), 5381);
    expect(djb2('a'), 5381 * 33 + 97);
  });

  test('fingerprint differs for different inputs and is stable', () {
    expect(fingerprint('abc'), fingerprint('abc'));
    expect(fingerprint('abc'), isNot(fingerprint('abd')));
  });
}
