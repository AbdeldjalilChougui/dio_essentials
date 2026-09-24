import 'package:dio_essentials/dio_essentials.dart';
import 'package:test/test.dart';

import 'support/fake_adapter.dart';

void main() {
  group('JwtClaims.decodeUnverified', () {
    test('reads standard claims', () {
      final token = makeJwt({
        'sub': 'user-42',
        'exp': 1700000000,
        'iat': 1699990000,
        'role': 'admin',
      });
      final claims = JwtClaims.decodeUnverified(token);

      expect(claims.subject, 'user-42');
      expect(claims.expiresAt, DateTime.utc(2023, 11, 14, 22, 13, 20));
      expect(claims.issuedAt,
          DateTime.fromMillisecondsSinceEpoch(1699990000000, isUtc: true));
      expect(claims['role'], 'admin');
      expect(claims.claims, containsPair('sub', 'user-42'));
    });

    test('handles base64url payloads without padding and non-ASCII', () {
      final token = makeJwt({'name': 'Élodie', 'exp': 1});
      expect(JwtClaims.decodeUnverified(token)['name'], 'Élodie');
    });

    test('accepts a leading "Bearer " prefix', () {
      final token = makeJwt({'sub': 'x'});
      expect(JwtClaims.decodeUnverified('Bearer $token').subject, 'x');
    });

    test('throws FormatException on malformed input', () {
      expect(() => JwtClaims.decodeUnverified(''), throwsFormatException);
      expect(() => JwtClaims.decodeUnverified('a.b'), throwsFormatException);
      expect(
          () => JwtClaims.decodeUnverified('a.!!!.c'), throwsFormatException);
      // Payload decodes but is not a JSON object.
      expect(
        () => JwtClaims.decodeUnverified('eyJ.WzFd.x'),
        throwsFormatException,
      );
    });

    test('tryDecodeUnverified returns null instead of throwing', () {
      expect(JwtClaims.tryDecodeUnverified('garbage'), isNull);
      expect(JwtClaims.tryDecodeUnverified(null), isNull);
      expect(JwtClaims.tryDecodeUnverified(makeJwt({'a': 1})), isNotNull);
    });

    test('missing or non-numeric exp gives null expiry', () {
      expect(JwtClaims.decodeUnverified(makeJwt({})).expiresAt, isNull);
      expect(
        JwtClaims.decodeUnverified(makeJwt({'exp': 'soon'})).expiresAt,
        isNull,
      );
    });
  });

  group('expiresWithin', () {
    final now = DateTime.utc(2026, 1, 1, 12);
    final exp = now.add(const Duration(minutes: 2));
    final claims = JwtClaims.decodeUnverified(
      makeJwt({'exp': exp.millisecondsSinceEpoch ~/ 1000}),
    );

    test('false when expiry is beyond the leeway', () {
      expect(
          claims.expiresWithin(const Duration(seconds: 60), now: now), isFalse);
    });

    test('true when expiry is inside the leeway', () {
      expect(
          claims.expiresWithin(const Duration(minutes: 3), now: now), isTrue);
    });

    test('true when already expired', () {
      expect(
        claims.expiresWithin(Duration.zero,
            now: exp.add(const Duration(seconds: 1))),
        isTrue,
      );
    });

    test('false when there is no exp claim', () {
      final noExp = JwtClaims.decodeUnverified(makeJwt({}));
      expect(noExp.expiresWithin(const Duration(days: 999), now: now), isFalse);
    });
  });
}
