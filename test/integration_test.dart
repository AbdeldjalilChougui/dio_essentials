import 'dart:async';

import 'package:dio_essentials/dio_essentials.dart';
import 'package:test/test.dart';

import 'support/fake_adapter.dart';

void main() {
  test('all four interceptors compose in the recommended order', () async {
    var token = 'old';
    var refreshes = 0;
    var flaky = 1; // first authorised call fails with 503 once
    final logs = <String>[];
    final gate = Completer<void>();

    final adapter = FakeAdapter((o, i) async {
      await gate.future;
      if (o.path == '/auth/refresh') return jsonBody({'access': 'new'});
      if (o.headers['Authorization'] != 'Bearer new') {
        return jsonBody({'detail': 'expired'}, status: 401);
      }
      if (flaky-- > 0) return jsonBody({}, status: 503);
      return jsonBody({
        'items': [1, 2, 3]
      });
    });
    final dio = fakeDio(adapter);
    final clock = FakeClock();
    dio.interceptors.addAll([
      DedupInterceptor(dio: dio),
      RedactingLogInterceptor(sink: logs.add),
      AuthRefreshInterceptor(
        dio: dio,
        tokenProvider: () async => token,
        refreshToken: () async {
          refreshes++;
          final res = await dio.post<dynamic>('/auth/refresh');
          return token = res.data['access'] as String;
        },
        skipPaths: const ['/auth/*'],
      ),
      RetryInterceptor(dio: dio, sleep: clock.sleep, clock: clock.call),
    ]);

    final calls = List.generate(10, (_) => dio.get<dynamic>('/items'));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    gate.complete();
    final results = await Future.wait(calls);

    expect(
        results.map((r) => r.data),
        everyElement({
          'items': [1, 2, 3]
        }));
    expect(refreshes, 1);
    // 1 deduplicated call (401) + refresh + replay (503) + retry (200).
    expect(adapter.calls, 4);
    expect(clock.sleeps, hasLength(1));
    final log = logs.join('\n');
    // The logger sits before auth and retry, so it sees every attempt.
    expect(log, contains('<-x 401 GET https://api.test/items'));
    expect(log, contains('<-x 503 GET https://api.test/items'));
    expect(log, contains('<-- 200 GET https://api.test/items'));
    expect(log, contains('<-- 200 POST https://api.test/auth/refresh'));
    expect(logs.join('\n'), isNot(contains('Bearer new')));
    expect(logs.join('\n'), isNot(contains('Bearer old')));
  });
}
