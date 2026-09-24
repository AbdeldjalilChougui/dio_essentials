// A self-contained tour of dio_essentials. It uses an in-memory adapter so it
// runs offline: `dart run example/main.dart`. In an app, drop the adapter and
// point `baseUrl` at your API.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_essentials/dio_essentials.dart';

Future<void> main() async {
  var accessToken = 'expired-token';

  final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
    ..httpClientAdapter = _DemoServer();

  // Recommended order: dedup first, then the logger so it sees every
  // attempt (including the 401 and 503 that are recovered below).
  dio.interceptors.addAll([
    DedupInterceptor(dio: dio, cacheTtl: const Duration(seconds: 2)),
    RedactingLogInterceptor(sink: print),
    AuthRefreshInterceptor(
      dio: dio,
      tokenProvider: () async => accessToken,
      refreshToken: () async {
        // Requests made in here bypass this interceptor automatically.
        final res = await dio.post<Map<String, dynamic>>(
          '/auth/refresh',
          data: {'refresh': 'stored-refresh-token'},
        );
        return accessToken = res.data!['access'] as String;
      },
      onSessionExpired: () => print('Session expired: show the login screen'),
      skipPaths: const ['/auth/*'],
      proactiveLeeway: const Duration(seconds: 30),
    ),
    RetryInterceptor(dio: dio, baseDelay: const Duration(milliseconds: 50)),
  ]);

  // Three identical calls at once: one network request, one token refresh.
  final results = await Future.wait([
    dio.get<dynamic>('/profile'),
    dio.get<dynamic>('/profile'),
    dio.get<dynamic>('/profile'),
  ]);
  print('Got ${results.length} responses: ${results.first.data}');

  // A write that carries an Idempotency-Key may be retried safely.
  await dio.post<dynamic>(
    '/orders',
    data: {'item': 'tea', 'qty': 2},
    options: Options(headers: {'Idempotency-Key': 'order-7f3a'}),
  );

  final claims = JwtClaims.tryDecodeUnverified(accessToken);
  print('Token subject (unverified): ${claims?.subject}');
}

/// A fake API: rejects the expired token, fails the first order with 503.
class _DemoServer implements HttpClientAdapter {
  var _orderAttempts = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (options.path == '/auth/refresh') {
      return _json({
        'access': _jwt({'sub': 'amina', 'exp': 4102444800})
      });
    }
    final auth = options.headers['Authorization'] as String? ?? '';
    if (!auth.startsWith('Bearer eyJ')) {
      return _json({'detail': 'token expired'}, 401);
    }
    if (options.path == '/orders' && _orderAttempts++ == 0) {
      return _json({'detail': 'try again'}, 503);
    }
    return _json({'name': 'Amina', 'password_hint': 'never logged'});
  }

  @override
  void close({bool force = false}) {}

  static ResponseBody _json(Object body, [int status = 200]) =>
      ResponseBody.fromString(jsonEncode(body), status, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });

  static String _jwt(Map<String, Object> claims) {
    String part(Object o) =>
        base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
    return '${part({'alg': 'none'})}.${part(claims)}.';
  }
}
