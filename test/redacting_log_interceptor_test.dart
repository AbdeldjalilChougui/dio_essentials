import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:dio_essentials/dio_essentials.dart';
import 'package:test/test.dart';

import 'support/fake_adapter.dart';

class _Harness {
  _Harness(
    FakeHandler handler, {
    int maxBodyChars = 4000,
    Set<String>? redactKeys,
    void Function(String)? sink,
  }) {
    adapter = FakeAdapter(handler);
    dio = fakeDio(adapter);
    dio.interceptors.add(RedactingLogInterceptor(
      sink: sink ?? lines.add,
      maxBodyChars: maxBodyChars,
      redactKeys: redactKeys ?? RedactingLogInterceptor.defaultRedactKeys,
      clock: clock.call,
    ));
  }

  final lines = <String>[];
  final clock = FakeClock();
  late final FakeAdapter adapter;
  late final Dio dio;

  String get all => lines.join('\n');
}

class _LeakyError implements Exception {
  _LeakyError(this.text);
  final String text;
  @override
  String toString() => text;
}

final _jwt = makeJwt({'sub': 'user-1', 'exp': 1900000000});
final _otherJwt = makeJwt({'sub': 'user-2', 'exp': 1900000000});
final _fingerprint = RegExp(r'jwt#[0-9a-f]{6}');

void main() {
  group('request line and format', () {
    test('logs method, URL and a correlation id on request and response',
        () async {
      final h = _Harness((o, i) => jsonBody({'ok': true}));
      await h.dio.get<dynamic>('/items', queryParameters: {'page': 2});
      expect(h.lines, hasLength(2));
      expect(
          h.lines[0], startsWith('--> GET https://api.test/items?page=2 #1'));
      expect(h.lines[1],
          startsWith('<-- 200 GET https://api.test/items?page=2 #1'));
      expect(h.lines[1], contains('{"ok":true}'));
    });

    test('reports the duration using the injected clock', () async {
      late _Harness h;
      h = _Harness((o, i) {
        h.clock.now = h.clock.now.add(const Duration(milliseconds: 25));
        return jsonBody({});
      });
      await h.dio.get<dynamic>('/x');
      expect(h.lines[1], contains('25ms'));
    });

    test('does not change what is actually sent', () async {
      final h = _Harness((o, i) => jsonBody({}));
      await h.dio.post<dynamic>(
        '/login',
        data: {'password': 'hunter22'},
        options: Options(headers: {'Authorization': 'Bearer $_jwt'}),
      );
      final sent = h.adapter.requests.single;
      expect(sent.headers['Authorization'], 'Bearer $_jwt');
      expect(sent.data, {'password': 'hunter22'});
    });
  });

  group('header redaction', () {
    test('redacts authorization and fingerprints the JWT', () async {
      final h = _Harness((o, i) => jsonBody({}));
      await h.dio.get<dynamic>('/me',
          options: Options(headers: {'Authorization': 'Bearer $_jwt'}));
      expect(h.all, isNot(contains(_jwt)));
      expect(
          h.all,
          contains(RegExp(r'authorization: \[REDACTED jwt#[0-9a-f]{6}\]',
              caseSensitive: false)));
    });

    test('redacts cookie, set-cookie and api keys case-insensitively',
        () async {
      final h = _Harness((o, i) => jsonBody({}, headers: {
            'Set-Cookie': ['sessionid=s3cr3t-cookie; HttpOnly'],
          }));
      await h.dio.get<dynamic>('/me',
          options: Options(headers: {
            'COOKIE': 'sessionid=abc-cookie-value',
            'X-API-KEY': 'key-0123456789',
            'X-Request-Id': 'req-42',
          }));
      expect(h.all, isNot(contains('abc-cookie-value')));
      expect(h.all, isNot(contains('s3cr3t-cookie')));
      expect(h.all, isNot(contains('key-0123456789')));
      expect(h.all, contains('req-42'));
    });
  });

  group('body redaction', () {
    const secrets = [
      'hunter22',
      'k-123456789',
      'refresh-abcdef',
      'client-secret-xyz',
      'PIN-SECRET-1',
    ];

    test('redacts keys inside nested JSON maps and lists', () async {
      final h = _Harness((o, i) => jsonBody({}));
      await h.dio.post<dynamic>('/sync', data: {
        'user': {
          'name': 'Amina',
          'PassWord': 'hunter22',
          'profile': {'Api_Key': 'k-123456789', 'city': 'Oran'},
        },
        'items': [
          {'refresh_token': 'refresh-abcdef', 'qty': 3},
          {
            'nested': [
              {'client_secret': 'client-secret-xyz'},
            ],
          },
        ],
        'extra': {'secretPin': 'PIN-SECRET-1'},
      });
      for (final s in secrets) {
        expect(h.all, isNot(contains(s)), reason: s);
      }
      expect(h.all, contains('Amina'));
      expect(h.all, contains('Oran'));
      expect(h.all, contains('"qty":3'));
      expect(h.all, contains('"PassWord":"[REDACTED]"'));
    });

    test('redacts a pre-encoded JSON string body', () async {
      final h = _Harness((o, i) => jsonBody({}));
      await h.dio.post<dynamic>('/login',
          data: jsonEncode({'username': 'bob', 'password': 'hunter22'}));
      expect(h.all, isNot(contains('hunter22')));
      expect(h.all, contains('bob'));
    });

    test('redacts a form-urlencoded body', () async {
      final h = _Harness((o, i) => jsonBody({}));
      await h.dio.post<dynamic>(
        '/login',
        data: {'username': 'bob', 'password': 'hunter22'},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      await h.dio.post<dynamic>(
        '/login',
        data: 'username=bob&password=hunter22',
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      expect(h.all, isNot(contains('hunter22')));
      expect(h.all, contains('bob'));
    });

    test('redacts FormData fields and summarises files', () async {
      final h = _Harness((o, i) => jsonBody({}));
      await h.dio.post<dynamic>(
        '/upload',
        data: FormData.fromMap({
          'token': 'form-token-123',
          'title': 'holiday',
          'file': MultipartFile.fromBytes([1, 2, 3], filename: 'a.png'),
        }),
      );
      expect(h.all, isNot(contains('form-token-123')));
      expect(h.all, contains('holiday'));
      expect(h.all, contains('a.png'));
    });

    test('redacts access and refresh tokens in a login response', () async {
      final h = _Harness((o, i) => jsonBody({
            'access': _jwt,
            'refresh': 'opaque-refresh-token',
            'user': {'id': 7},
          }));
      await h.dio.post<dynamic>('/auth/login', data: {'u': 'x'});
      expect(h.all, isNot(contains(_jwt)));
      expect(h.all, isNot(contains('opaque-refresh-token')));
      expect(h.all, contains('"id":7'));
    });

    test('custom redact keys are honoured', () async {
      final h = _Harness(
        (o, i) => jsonBody({}),
        redactKeys: {...RedactingLogInterceptor.defaultRedactKeys, 'email'},
      );
      await h.dio.post<dynamic>('/x', data: {'Email': 'a@b.dz', 'n': 1});
      expect(h.all, isNot(contains('a@b.dz')));
    });

    test('byte bodies are summarised, not dumped', () async {
      final h = _Harness((o, i) => jsonBody({}));
      await h.dio.post<dynamic>('/bin', data: List<int>.filled(10, 7));
      expect(h.lines.first, contains('<10 bytes>'));
    });
  });

  group('query parameters', () {
    test('redacts secret query parameters but keeps the rest', () async {
      final h = _Harness((o, i) => jsonBody({}));
      await h.dio.get<dynamic>('/search', queryParameters: {
        'access_token': 'qs-secret-123',
        'page': 2,
      });
      await h.dio.get<dynamic>('/search?API-KEY=inline-key-456&q=tea');
      expect(h.all, isNot(contains('qs-secret-123')));
      expect(h.all, isNot(contains('inline-key-456')));
      expect(h.all, contains('page=2'));
      expect(h.all, contains('q=tea'));
      expect(h.all, contains('access_token=[REDACTED]'));
    });

    test('redacts credentials in the URL user-info', () async {
      final h = _Harness((o, i) => jsonBody({}));
      await h.dio.get<dynamic>('https://bob:pa55word@api.test/x');
      expect(h.all, isNot(contains('pa55word')));
    });
  });

  group('JWT fingerprints', () {
    test('replaces a JWT found anywhere with a short stable fingerprint',
        () async {
      final h = _Harness((o, i) => jsonBody({'note': 'yours is $_jwt ok'}));
      await h.dio.post<dynamic>('/x', data: {'comment': 'mine is $_jwt'});
      expect(h.all, isNot(contains(_jwt)));
      final prints = _fingerprint.allMatches(h.all).map((m) => m[0]).toSet();
      expect(prints, hasLength(1), reason: 'same token, same fingerprint');
    });

    test('different tokens get different fingerprints', () {
      expect(
        RedactingLogInterceptor.jwtFingerprint(_jwt),
        isNot(RedactingLogInterceptor.jwtFingerprint(_otherJwt)),
      );
      expect(
          RedactingLogInterceptor.jwtFingerprint(_jwt), matches(_fingerprint));
    });

    test('scrubs JWTs in a query string', () async {
      final h = _Harness((o, i) => jsonBody({}));
      await h.dio.get<dynamic>('/ws', queryParameters: {'t': _jwt});
      expect(h.all, isNot(contains(_jwt)));
      expect(h.all, contains(_fingerprint));
    });
  });

  group('truncation and HTML detection', () {
    test('truncates large bodies', () async {
      final big = 'x' * 5000;
      final h = _Harness((o, i) => jsonBody({'blob': big}), maxBodyChars: 100);
      await h.dio.get<dynamic>('/big');
      expect(h.lines[1].length, lessThan(400));
      expect(h.lines[1], contains('truncated'));
    });

    test('redaction happens before truncation', () async {
      final h = _Harness(
        (o, i) => jsonBody({'pad': 'y' * 50, 'password': 'hunter22'}),
        maxBodyChars: 70,
      );
      await h.dio.get<dynamic>('/x');
      expect(h.all, isNot(contains('hunter')));
    });

    test('flags an HTML response to a JSON endpoint', () async {
      final h = _Harness((o, i) => textBody(
            '<!DOCTYPE html><html><body>Login</body></html>',
            contentType: 'text/html; charset=utf-8',
          ));
      await h.dio.get<dynamic>('/api/items');
      expect(h.lines[1], contains('HTML response to a JSON endpoint'));
    });

    test('flags HTML on the error path too', () async {
      final h = _Harness((o, i) => textBody('<html>502 Bad Gateway</html>',
          status: 502, contentType: 'text/html'));
      await expectLater(h.dio.get<dynamic>('/api/items'), throwsA(anything));
      expect(h.lines[1], contains('HTML response to a JSON endpoint'));
    });

    test('does not flag HTML when plain text was requested', () async {
      final h = _Harness(
          (o, i) => textBody('<html></html>', contentType: 'text/html'));
      await h.dio.get<dynamic>('/page',
          options: Options(responseType: ResponseType.plain));
      expect(h.all, isNot(contains('HTML response')));
    });
  });

  group('error path', () {
    test('redacts the error response body', () async {
      final h = _Harness((o, i) =>
          jsonBody({'detail': 'bad', 'refresh': 'leaky-refresh'}, status: 401));
      await expectLater(h.dio.get<dynamic>('/me'), throwsA(anything));
      expect(h.lines[1], startsWith('<-x 401 GET https://api.test/me #1'));
      expect(h.all, isNot(contains('leaky-refresh')));
    });

    test('never leaks secrets carried by the error or its message', () async {
      final h = _Harness((o, i) {
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.connectionError,
          message: 'connect failed; password=hunter22; Bearer $_jwt',
          error: _LeakyError(
            'GET https://api.test/me?access_token=qs-secret-123 '
            'Authorization: Bearer opaque-bearer-999 '
            'body {"password":"hunter22"} and $_jwt',
          ),
        );
      });
      await expectLater(
        h.dio.post<dynamic>(
          '/me',
          data: {'password': 'hunter22'},
          queryParameters: {'access_token': 'qs-secret-123'},
          options:
              Options(headers: {'authorization': 'Bearer opaque-bearer-999'}),
        ),
        throwsA(anything),
      );
      for (final s in [
        'hunter22',
        _jwt,
        'qs-secret-123',
        'opaque-bearer-999',
      ]) {
        expect(h.all, isNot(contains(s)), reason: s);
      }
      expect(h.lines.last, contains('connectionError'));
      expect(h.lines.last, contains('_LeakyError'));
    });

    test('removes redacted request values even when they appear bare',
        () async {
      // No key, no pattern: only the "values we already redacted" rule
      // catches this.
      final h = _Harness((o, i) {
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.unknown,
          error: _LeakyError('login as amina with hunter22 failed'),
        );
      });
      await expectLater(
        h.dio.post<dynamic>('/login',
            data: {'user': 'amina', 'password': 'hunter22'}),
        throwsA(anything),
      );
      expect(h.all, isNot(contains('hunter22')));
      expect(h.lines.last, contains('login as amina with [REDACTED] failed'));
    });

    test('a sink that throws never breaks the request', () async {
      final adapter = FakeAdapter((o, i) => jsonBody({'ok': true}));
      final dio = fakeDio(adapter)
        ..interceptors.add(RedactingLogInterceptor(
          sink: (_) => throw StateError('disk full'),
        ));
      final res = await dio.get<dynamic>('/x');
      expect(res.data, {'ok': true});
      await expectLater(
        dio.get<dynamic>('/y', options: Options(validateStatus: (s) => false)),
        throwsA(isA<DioException>()
            .having((e) => e.error, 'error', isNot(isA<StateError>()))),
      );
    });

    test('the error still reaches the caller unchanged', () async {
      final h = _Harness((o, i) => jsonBody({'e': 1}, status: 500));
      await expectLater(
        h.dio.get<dynamic>('/x'),
        throwsA(isA<DioException>()
            .having((e) => e.response?.statusCode, 'status', 500)
            .having((e) => e.response?.data, 'data', {'e': 1})),
      );
    });
  });

  group('redact helper', () {
    test('redactJson masks nested keys without mutating the input', () {
      final input = <String, dynamic>{
        'a': {'Token': 't-1'},
        'b': [
          {'secret': 's'},
        ],
      };
      final out = RedactingLogInterceptor().redactJson(input);
      expect(out, {
        'a': {'Token': '[REDACTED]'},
        'b': [
          {'secret': '[REDACTED]'},
        ],
      });
      expect(input['a'], {'Token': 't-1'});
    });
  });
}
