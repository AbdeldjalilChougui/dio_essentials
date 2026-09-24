import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio_essentials/dio_essentials.dart';
import 'package:test/test.dart';

import 'support/fake_adapter.dart';

/// A tiny token store plus a fake server that accepts only [valid] tokens.
class _Harness {
  _Harness({
    String? initialToken = 'old',
    List<String> skipPaths = const ['/auth/*'],
    Duration? proactiveLeeway,
    DateTime Function()? clock,
    this.gateRefresh = false,
    String headerName = 'Authorization',
    String Function(String)? formatHeader,
  }) : token = initialToken {
    adapter = FakeAdapter(handle);
    dio = fakeDio(adapter);
    interceptor = AuthRefreshInterceptor(
      dio: dio,
      tokenProvider: () async => token,
      refreshToken: refresh,
      onSessionExpired: () => expired++,
      skipPaths: skipPaths,
      proactiveLeeway: proactiveLeeway,
      clock: clock,
      headerName: headerName,
      formatHeader: formatHeader ?? AuthRefreshInterceptor.bearer,
    );
    dio.interceptors.add(interceptor);
  }

  String? token;
  Object? refreshResult = 'new'; // a String, null, or an Exception to throw
  final bool gateRefresh;
  final refreshGate = Completer<void>();
  final Set<String> valid = {'new'};
  late final FakeAdapter adapter;
  late final Dio dio;
  late final AuthRefreshInterceptor interceptor;
  int refreshes = 0;
  int expired = 0;

  /// Optional per-request hold, to control when 401s arrive.
  Future<void> Function(RequestOptions o)? hold;

  Future<ResponseBody> handle(RequestOptions o, int i) async {
    if (hold != null) await hold!(o);
    if (o.path.startsWith('/auth/') || o.path == '/public') {
      return jsonBody({'public': true});
    }
    final header = o.headers['Authorization'] as String?;
    final presented = header?.replaceFirst('Bearer ', '');
    if (presented == null || !valid.contains(presented)) {
      return jsonBody({'detail': 'unauthorized'}, status: 401);
    }
    return jsonBody({'ok': true, 'path': o.path});
  }

  Future<String?> refresh() async {
    refreshes++;
    if (gateRefresh) await refreshGate.future;
    final r = refreshResult;
    if (r is Exception) throw r;
    token = r as String?;
    return token;
  }

  /// Requests that actually reached the server with the given token.
  int sentWith(String token) => adapter.requests
      .where((r) => r.headers['Authorization'] == 'Bearer $token')
      .length;
}

Future<void> _ticks([int n = 30]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final Matcher _sessionExpired401 = isA<DioException>()
    .having((e) => e.response?.statusCode, 'status', 401)
    .having((e) => e.error, 'error', isA<SessionExpiredException>());

void main() {
  group('attaching the token', () {
    test('adds a Bearer header from the async provider', () async {
      final h = _Harness(initialToken: 'new');
      await h.dio.get<dynamic>('/me');
      expect(h.adapter.requests.single.headers['Authorization'], 'Bearer new');
    });

    test('sends no header when the provider returns null', () async {
      final h = _Harness(initialToken: null);
      await expectLater(
          h.dio.get<dynamic>('/me'), throwsA(isA<DioException>()));
      expect(h.adapter.requests.single.headers.containsKey('Authorization'),
          isFalse);
    });

    test('does not refresh a 401 for a request that carried no token',
        () async {
      final h = _Harness(initialToken: null);
      await expectLater(
          h.dio.get<dynamic>('/me'), throwsA(isA<DioException>()));
      expect(h.refreshes, 0);
      expect(h.expired, 0);
    });

    test('custom header name and format', () async {
      final h = _Harness(
        initialToken: 'new',
        headerName: 'X-Api-Token',
        formatHeader: (t) => 'Token $t',
      );
      h.valid.clear(); // the fake server only checks Authorization; ignore.
      await expectLater(h.dio.get<dynamic>('/me'), throwsA(anything));
      expect(h.adapter.requests.first.headers['X-Api-Token'], 'Token new');
      expect(h.adapter.requests.first.headers.containsKey('Authorization'),
          isFalse);
    });

    test('skipped paths get no token and no refresh', () async {
      final h = _Harness();
      await h.dio.post<dynamic>('/auth/login', data: {'u': 'x'});
      expect(h.adapter.requests.single.headers.containsKey('Authorization'),
          isFalse);
    });

    test('exact skip paths match only that path', () async {
      final h = _Harness(initialToken: 'new', skipPaths: ['/public']);
      await h.dio.get<dynamic>('/public');
      await h.dio.get<dynamic>('/public/x');
      expect(
          h.adapter.requests[0].headers.containsKey('Authorization'), isFalse);
      expect(h.adapter.requests[1].headers['Authorization'], 'Bearer new');
    });

    test('a request can opt out through extra', () async {
      final h = _Harness(initialToken: 'new');
      await expectLater(
        h.dio.get<dynamic>('/me',
            options:
                Options(extra: {AuthRefreshInterceptor.skipExtraKey: true})),
        throwsA(isA<DioException>()),
      );
      expect(h.adapter.requests.single.headers.containsKey('Authorization'),
          isFalse);
      expect(h.refreshes, 0);
    });
  });

  group('refresh on 401', () {
    test('refreshes once and replays with the new token', () async {
      final h = _Harness();
      final res = await h.dio.get<dynamic>('/me');
      expect(res.data, containsPair('ok', true));
      expect(h.refreshes, 1);
      expect(h.adapter.requests.map((r) => r.headers['Authorization']),
          ['Bearer old', 'Bearer new']);
    });

    test('10 parallel 401s trigger exactly 1 refresh and each replays once',
        () async {
      final h = _Harness(gateRefresh: true);
      final calls = List.generate(10, (i) => h.dio.get<dynamic>('/r$i'));
      await _ticks();
      expect(h.refreshes, 1);
      h.refreshGate.complete();
      final results = await Future.wait(calls);

      expect(h.refreshes, 1);
      expect(results.map((r) => r.statusCode), everyElement(200));
      expect(h.sentWith('old'), 10);
      expect(h.sentWith('new'), 10);
      for (var i = 0; i < 10; i++) {
        expect(
          h.adapter.requests.where((r) => r.path == '/r$i').length,
          2,
          reason: '/r$i must be sent once and replayed once',
        );
      }
      expect(h.expired, 0);
    });

    test('a 401 that arrives after the refresh finished reuses the new token',
        () async {
      final h = _Harness();
      final late = Completer<void>();
      h.hold = (o) async {
        if (o.path == '/slow' && o.headers['Authorization'] == 'Bearer old') {
          await late.future;
        }
      };
      final slow = h.dio.get<dynamic>('/slow');
      await _ticks();
      await h.dio.get<dynamic>('/fast'); // triggers and finishes the refresh
      expect(h.refreshes, 1);
      late.complete(); // /slow now fails with the old token
      final res = await slow;
      expect(res.statusCode, 200);
      expect(h.refreshes, 1, reason: 'no second refresh for a stale 401');
    });

    test('a failing refresh fails every waiter and expires the session once',
        () async {
      final h = _Harness(gateRefresh: true)
        ..refreshResult = Exception('refresh token revoked');
      final calls = List.generate(
        10,
        (i) => h.dio.get<dynamic>('/r$i').then<Object?>(
              (r) => r,
              onError: (Object e) => e,
            ),
      );
      await _ticks();
      h.refreshGate.complete();
      final results = await Future.wait(calls);

      expect(results, everyElement(_sessionExpired401));
      expect(h.refreshes, 1);
      expect(h.expired, 1);
      expect(h.sentWith('new'), 0);
    });

    test('a refresh returning null counts as failure', () async {
      final h = _Harness()..refreshResult = null;
      await expectLater(h.dio.get<dynamic>('/me'), throwsA(_sessionExpired401));
      expect(h.expired, 1);
    });

    test('a replay that gets 401 again is not refreshed again', () async {
      final h = _Harness()..valid.clear(); // server rejects every token
      await expectLater(
        h.dio.get<dynamic>('/me'),
        throwsA(isA<DioException>()
            .having((e) => e.response?.statusCode, 'status', 401)),
      );
      expect(h.refreshes, 1);
      expect(h.adapter.calls, 2);
    });

    test('non-401 errors pass straight through', () async {
      final adapter = FakeAdapter((o, i) => jsonBody({}, status: 403));
      final dio = fakeDio(adapter);
      var refreshes = 0;
      dio.interceptors.add(AuthRefreshInterceptor(
        dio: dio,
        tokenProvider: () async => 't',
        refreshToken: () async {
          refreshes++;
          return 'n';
        },
      ));
      await expectLater(
        dio.get<dynamic>('/x'),
        throwsA(isA<DioException>()
            .having((e) => e.response?.statusCode, 'status', 403)),
      );
      expect(refreshes, 0);
    });

    test('a 401 on a skipped path is not refreshed', () async {
      final adapter = FakeAdapter((o, i) => jsonBody({}, status: 401));
      final dio = fakeDio(adapter);
      var refreshes = 0;
      dio.interceptors.add(AuthRefreshInterceptor(
        dio: dio,
        tokenProvider: () async => 't',
        refreshToken: () async {
          refreshes++;
          return 'n';
        },
        skipPaths: const ['/auth/login'],
      ));
      await expectLater(
          dio.post<dynamic>('/auth/login'), throwsA(isA<DioException>()));
      expect(refreshes, 0);
    });
  });

  group('the refresh request itself', () {
    test('bypasses the interceptor even on the same Dio without marking',
        () async {
      // The refresh endpoint rejects the refresh token with 401. Without the
      // bypass this would recurse into another refresh and deadlock.
      final adapter = FakeAdapter((o, i) => jsonBody({}, status: 401));
      final dio = fakeDio(adapter);
      var refreshes = 0;
      var expired = 0;
      dio.interceptors.add(AuthRefreshInterceptor(
        dio: dio,
        tokenProvider: () async => 'old',
        refreshToken: () async {
          refreshes++;
          final res =
              await dio.post<dynamic>('/token/refresh', data: {'refresh': 'r'});
          return res.data['access'] as String?;
        },
        onSessionExpired: () => expired++,
      ));

      await expectLater(
        dio.get<dynamic>('/me').timeout(const Duration(seconds: 5)),
        throwsA(_sessionExpired401),
      );
      expect(refreshes, 1);
      expect(expired, 1);
      final refreshCall =
          adapter.requests.singleWhere((r) => r.path == '/token/refresh');
      expect(refreshCall.headers.containsKey('Authorization'), isFalse);
    });

    test('a successful refresh through the same Dio replays the request',
        () async {
      var token = 'old';
      final adapter = FakeAdapter((o, i) {
        if (o.path == '/token/refresh') return jsonBody({'access': 'new'});
        return o.headers['Authorization'] == 'Bearer new'
            ? jsonBody({'ok': true})
            : jsonBody({}, status: 401);
      });
      final dio = fakeDio(adapter);
      dio.interceptors.add(AuthRefreshInterceptor(
        dio: dio,
        tokenProvider: () async => token,
        refreshToken: () async {
          final res = await dio.post<dynamic>('/token/refresh');
          token = res.data['access'] as String;
          return token;
        },
      ));
      final res = await dio.get<dynamic>('/me');
      expect(res.data, {'ok': true});
    });
  });

  group('proactive refresh', () {
    final now = DateTime.utc(2026, 5, 1, 10);
    String jwtExpiringIn(Duration d) =>
        makeJwt({'exp': now.add(d).millisecondsSinceEpoch ~/ 1000});

    test('refreshes before sending when exp is within the leeway', () async {
      final h = _Harness(
        initialToken: jwtExpiringIn(const Duration(seconds: 20)),
        proactiveLeeway: const Duration(seconds: 60),
        clock: () => now,
      );
      final res = await h.dio.get<dynamic>('/me');
      expect(res.statusCode, 200);
      expect(h.refreshes, 1);
      expect(h.adapter.calls, 1, reason: 'the stale token was never sent');
      expect(h.sentWith('new'), 1);
    });

    test('concurrent requests share one proactive refresh', () async {
      final h = _Harness(
        initialToken: jwtExpiringIn(const Duration(seconds: 5)),
        proactiveLeeway: const Duration(seconds: 60),
        clock: () => now,
        gateRefresh: true,
      );
      final calls = List.generate(5, (i) => h.dio.get<dynamic>('/r$i'));
      await _ticks();
      h.refreshGate.complete();
      await Future.wait(calls);
      expect(h.refreshes, 1);
      expect(h.sentWith('new'), 5);
    });

    test('does nothing when exp is outside the leeway', () async {
      final t = jwtExpiringIn(const Duration(hours: 1));
      final h = _Harness(
        initialToken: t,
        proactiveLeeway: const Duration(seconds: 60),
        clock: () => now,
      )..valid.add(t);
      await h.dio.get<dynamic>('/me');
      expect(h.refreshes, 0);
    });

    test('does nothing for opaque (non-JWT) tokens', () async {
      final h = _Harness(
        initialToken: 'new',
        proactiveLeeway: const Duration(days: 365),
        clock: () => now,
      );
      await h.dio.get<dynamic>('/me');
      expect(h.refreshes, 0);
    });

    test('a failed proactive refresh rejects the request and expires once',
        () async {
      final h = _Harness(
        initialToken: jwtExpiringIn(Duration.zero),
        proactiveLeeway: const Duration(seconds: 60),
        clock: () => now,
      )..refreshResult = null;
      await expectLater(
        h.dio.get<dynamic>('/me'),
        throwsA(isA<DioException>()
            .having((e) => e.error, 'error', isA<SessionExpiredException>())),
      );
      expect(h.adapter.calls, 0);
      expect(h.expired, 1);
    });
  });
}
