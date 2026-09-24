/// Small non-cryptographic string hashes that give identical results on the
/// VM and on the web (all arithmetic stays below 2^53).
library;

const _two32 = 0x100000000;

/// 32-bit FNV-1a over the UTF-16 code units of [input].
int fnv1a32(String input) {
  var hash = 0x811c9dc5;
  for (var i = 0; i < input.length; i++) {
    hash = (hash ^ input.codeUnitAt(i)) % _two32;
    // hash * 16777619 == hash * 2^24 + hash * 403, split to stay exact.
    hash = ((hash % 256) * 16777216 + hash * 403) % _two32;
  }
  return hash;
}

/// 32-bit djb2 (`h * 33 + c`) over the UTF-16 code units of [input].
int djb2(String input) {
  var hash = 5381;
  for (var i = 0; i < input.length; i++) {
    hash = (hash * 33 + input.codeUnitAt(i)) % _two32;
  }
  return hash;
}

/// A compact fingerprint of [input]: its length plus two independent 32-bit
/// hashes, as hex. Collisions are negligible for request keys.
String fingerprint(String input) =>
    '${input.length.toRadixString(36)}.${fnv1a32(input).toRadixString(16)}'
    '.${djb2(input).toRadixString(16)}';
