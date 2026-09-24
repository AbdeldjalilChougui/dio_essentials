import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:dio_essentials/dio_essentials.dart';
import 'package:test/test.dart';

import 'support/fake_adapter.dart';

/// A [Random] whose [nextDouble] always returns [value].
class _FixedRandom implements Random {
  _FixedRandom(this.value);
  final double value;
  @override
  double nextDouble() => value;
  @override
  bool nextBool() => false;
  @override
  int nextInt(int max) => 0;
}

class _Harness {
  _Harness(
    FakeHandler handler, {
    int maxAttempts = 4,
    Duration baseDelay = const Duration(milliseconds: 100),
    Duration maxDelay = const Duration(seconds: 10),
    Duration maxRetryAfter = const Duration(minutes: 2),
    double jitter = 0.5,
    bool Function(DioException)? retryIf,
  }) {
    adapter = FakeAdapter(handler);
    dio = fakeDio(adapter);
    interceptor = RetryInterceptor(
      dio: dio,
      maxAttempts: maxAttempts,
      baseDelay: baseDelay,
      maxDelay: maxDelay,
      maxRetryAfter: maxRetryAfter,
      retryIf: retryIf ?? RetryInterceptor.isTransientError,
      random: _FixedRandom(jitter),
      clock: clock.call,
      sleep: clock.sleep,
      onRetry: events.add,
    );
    dio.interceptors.add(interceptor);
  }

  final clock = FakeClock();
  final events = <RetryEvent>[];
  late final FakeAdapter adapter;
  late final Dio dio;
  late final RetryInterceptor interceptor;
}

FakeHandler _failThenOk(int failures, {int status = 503}) {
  return (o, i) => i < failures
      ? jsonBody({'e': i}, status: status)
      : jsonBody({'ok': true});
}

Matcher _dioStatus(int status) => isA<DioException>()
    .having((e) => e.response?.statusCode, 'statusCode', status);

void main() {
  group('backoff', () {
    test('retries a GET on 503 and returns the eventual success', () async {
      final h = _Harness(_failThenOk(1));
      final res = await h.dio.get<dynamic>('/items');
      expect(res.data, {'ok': true});
      expect(h.adapter.calls, 2);
    });

    test('uses real exponential backoff with full jitter and a cap', () async {
      // base 100ms, cap 1s, jitter sample 0.5 → 0.5 * min(cap, base * 2^n).
      final h = _Harness(
        _failThenOk(5),
        maxAttempts: 6,
        maxDelay: const Duration(seconds: 1),
      );
      await h.dio.get<dynamic>('/items');
      expect(h.clock.sleeps, const [
        Duration(milliseconds: 50),
        Duration(milliseconds: 100),
        Duration(milliseconds: 200),
        Duration(milliseconds: 400),
        Duration(milliseconds: 500), // capped at 1s before jitter
      ]);
    });

    test('the first retry is delayed (not immediate)', () async {
      final h = _Harness(_failThenOk(1), jitter: 0.999);
      await h.dio.get<dynamic>('/items');
      expect(h.clock.sleeps.single, greaterThan(Duration.zero));
    });

    test('jitter spreads the delay between 0 and the exponential ceiling',
        () async {
      final low = _Harness(_failThenOk(1), jitter: 0.0);
      await low.dio.get<dynamic>('/a');
      final high = _Harness(_failThenOk(1), jitter: 0.99);
      await high.dio.get<dynamic>('/a');
      expect(low.clock.sleeps.single, Duration.zero);
      expect(high.clock.sleeps.single, const Duration(microseconds: 99000));
    });

    test('fake clock elapsed time equals the sum of backoff delays', () async {
      final h = _Harness(_failThenOk(3));
      final start = h.clock.now;
      await h.dio.get<dynamic>('/items');
      expect(h.clock.now.difference(start), const Duration(milliseconds: 350));
    });

    test('stops after maxAttempts total attempts and surfaces the last error',
        () async {
      final h = _Harness(_failThenOk(99), maxAttempts: 3);
      await expectLater(h.dio.get<dynamic>('/items'), throwsA(_dioStatus(503)));
      expect(h.adapter.calls, 3);
      expect(h.clock.sleeps, hasLength(2));
    });

    test('maxAttempts of 1 disables retrying', () async {
      final h = _Harness(_failThenOk(99), maxAttempts: 1);
      await expectLater(h.dio.get<dynamic>('/items'), throwsA(_dioStatus(503)));
      expect(h.adapter.calls, 1);
    });

    test('reports each retry through onRetry', () async {
      final h = _Harness(_failThenOk(2));
      await h.dio.get<dynamic>('/items');
      expect(h.events.map((e) => e.attempt), [1, 2]);
      expect(h.events.map((e) => e.delay), const [
        Duration(milliseconds: 50),
        Duration(milliseconds: 100),
      ]);
      expect(h.events.first.error.response?.statusCode, 503);
    });

    test('replays the same headers, query and body', () async {
      final h = _Harness(_failThenOk(1));
      await h.dio.put<dynamic>(
        '/items/1',
        data: {'name': 'x'},
        queryParameters: {'q': '1'},
        options: Options(headers: {'X-Trace': 'abc'}),
      );
      final replay = h.adapter.requests.last;
      expect(replay.data, {'name': 'x'});
      expect(replay.queryParameters, {'q': '1'});
      expect(replay.headers['X-Trace'], 'abc');
    });
  });

  group('Retry-After', () {
    test('honours the delay-seconds form exactly', () async {
      final h = _Harness((o, i) => i == 0
          ? jsonBody({},
              status: 429,
              headers: {
                'retry-after': ['7'],
              })
          : jsonBody({'ok': true}));
      await h.dio.get<dynamic>('/items');
      expect(h.clock.sleeps, const [Duration(seconds: 7)]);
    });

    test('honours the HTTP-date form relative to the injected clock', () async {
      late _Harness h;
      h = _Harness((o, i) {
        if (i > 0) return jsonBody({'ok': true});
        final at = h.clock.now.add(const Duration(seconds: 30));
        return jsonBody({},
            status: 503,
            headers: {
              'retry-after': [RetryInterceptor.formatHttpDate(at)],
            });
      });
      await h.dio.get<dynamic>('/items');
      expect(h.clock.sleeps, const [Duration(seconds: 30)]);
    });

    test('a date in the past means retry now', () async {
      final h = _Harness((o, i) => i == 0
          ? jsonBody({},
              status: 503,
              headers: {
                'retry-after': ['Sun, 06 Nov 1994 08:49:37 GMT'],
              })
          : jsonBody({'ok': true}));
      await h.dio.get<dynamic>('/items');
      expect(h.clock.sleeps, const [Duration.zero]);
    });

    test('a Retry-After longer than maxRetryAfter is not waited for', () async {
      final h = _Harness(
        (o, i) => jsonBody({},
            status: 503,
            headers: {
              'retry-after': ['3600'],
            }),
        maxRetryAfter: const Duration(minutes: 1),
      );
      await expectLater(h.dio.get<dynamic>('/items'), throwsA(_dioStatus(503)));
      expect(h.adapter.calls, 1);
      expect(h.clock.sleeps, isEmpty);
    });

    test('an unparseable Retry-After falls back to backoff', () async {
      final h = _Harness((o, i) => i == 0
          ? jsonBody({},
              status: 503,
              headers: {
                'retry-after': ['soon-ish'],
              })
          : jsonBody({'ok': true}));
      await h.dio.get<dynamic>('/items');
      expect(h.clock.sleeps, const [Duration(milliseconds: 50)]);
    });

    group('parseRetryAfter', () {
      final now = DateTime.utc(1994, 11, 6, 8, 49, 0);

      test('delay-seconds', () {
        expect(RetryInterceptor.parseRetryAfter('120', now),
            const Duration(seconds: 120));
        expect(RetryInterceptor.parseRetryAfter(' 0 ', now), Duration.zero);
      });

      test('IMF-fixdate', () {
        expect(
          RetryInterceptor.parseRetryAfter(
              'Sun, 06 Nov 1994 08:49:37 GMT', now),
          const Duration(seconds: 37),
        );
      });

      test('obsolete RFC 850 date', () {
        expect(
          RetryInterceptor.parseRetryAfter(
              'Sunday, 06-Nov-94 08:49:37 GMT', now),
          const Duration(seconds: 37),
        );
      });

      test('obsolete asctime date', () {
        expect(
          RetryInterceptor.parseRetryAfter('Sun Nov  6 08:49:37 1994', now),
          const Duration(seconds: 37),
        );
      });

      test('rejects garbage and negative numbers', () {
        expect(RetryInterceptor.parseRetryAfter('', now), isNull);
        expect(RetryInterceptor.parseRetryAfter('-5', now), isNull);
        expect(RetryInterceptor.parseRetryAfter('1.5', now), isNull);
        expect(
            RetryInterceptor.parseRetryAfter(
                'Sun, 32 Nov 1994 08:49:37 GMT', now),
            isNull);
        expect(RetryInterceptor.parseRetryAfter('tomorrow', now), isNull);
      });

      test('formatHttpDate round-trips', () {
        final t = DateTime.utc(2026, 3, 9, 7, 5, 3);
        expect(RetryInterceptor.formatHttpDate(t),
            'Mon, 09 Mar 2026 07:05:03 GMT');
        expect(
          RetryInterceptor.parseRetryAfter(
              RetryInterceptor.formatHttpDate(t), t),
          Duration.zero,
        );
      });
    });
  });

  group('method safety', () {
    for (final method in ['GET', 'HEAD', 'OPTIONS', 'PUT', 'DELETE']) {
      test('$method is retried by default', () async {
        final h = _Harness(_failThenOk(1));
        await h.dio.request<dynamic>('/r', options: Options(method: method));
        expect(h.adapter.calls, 2);
      });
    }

    for (final method in ['POST', 'PATCH']) {
      test('$method is NOT retried by default', () async {
        final h = _Harness(_failThenOk(1));
        await expectLater(
          h.dio.request<dynamic>('/r',
              data: {'a': 1}, options: Options(method: method)),
          throwsA(_dioStatus(503)),
        );
        expect(h.adapter.calls, 1);
      });

      test('$method with an Idempotency-Key header is retried', () async {
        final h = _Harness(_failThenOk(1));
        await h.dio.request<dynamic>(
          '/r',
          data: {'a': 1},
          options: Options(method: method, headers: {'idempotency-key': 'k1'}),
        );
        expect(h.adapter.calls, 2);
        expect(h.adapter.requests.last.headers['idempotency-key'], 'k1');
      });

      test('$method with the per-request opt-in is retried', () async {
        final h = _Harness(_failThenOk(1));
        await h.dio.request<dynamic>(
          '/r',
          data: {'a': 1},
          options: Options(
              method: method, extra: {RetryInterceptor.retryExtraKey: true}),
        );
        expect(h.adapter.calls, 2);
      });
    }

    test('an idempotent request can opt out through extra', () async {
      final h = _Harness(_failThenOk(1));
      await expectLater(
        h.dio.get<dynamic>('/r',
            options: Options(extra: {RetryInterceptor.retryExtraKey: false})),
        throwsA(_dioStatus(503)),
      );
      expect(h.adapter.calls, 1);
    });
  });

  group('what is retryable', () {
    for (final status in [408, 429, 502, 503, 504]) {
      test('status $status is retried', () async {
        final h = _Harness(_failThenOk(1, status: status));
        await h.dio.get<dynamic>('/r');
        expect(h.adapter.calls, 2);
      });
    }

    for (final status in [400, 401, 403, 404, 409, 422, 500, 501]) {
      test('status $status is not retried', () async {
        final h = _Harness(_failThenOk(1, status: status));
        await expectLater(
            h.dio.get<dynamic>('/r'), throwsA(_dioStatus(status)));
        expect(h.adapter.calls, 1);
      });
    }

    for (final type in [
      DioExceptionType.connectionError,
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
    ]) {
      test('${type.name} is retried', () async {
        final h = _Harness((o, i) {
          if (i == 0) throw DioException(requestOptions: o, type: type);
          return jsonBody({'ok': true});
        });
        await h.dio.get<dynamic>('/r');
        expect(h.adapter.calls, 2);
      });
    }

    test('badCertificate and unknown errors are not retried', () async {
      for (final type in [
        DioExceptionType.badCertificate,
        DioExceptionType.unknown,
      ]) {
        final h = _Harness((o, i) {
          if (i == 0) throw DioException(requestOptions: o, type: type);
          return jsonBody({'ok': true});
        });
        await expectLater(
            h.dio.get<dynamic>('/r'), throwsA(isA<DioException>()));
        expect(h.adapter.calls, 1, reason: type.name);
      }
    });

    test('a custom predicate replaces the default classification', () async {
      final h = _Harness(
        _failThenOk(1, status: 500),
        retryIf: (e) => e.response?.statusCode == 500,
      );
      await h.dio.get<dynamic>('/r');
      expect(h.adapter.calls, 2);
    });

    test('a custom predicate cannot force a POST retry', () async {
      final h = _Harness(_failThenOk(1), retryIf: (_) => true);
      await expectLater(
          h.dio.post<dynamic>('/r', data: {'a': 1}), throwsA(_dioStatus(503)));
      expect(h.adapter.calls, 1);
    });
  });

  group('never retried', () {
    test('a request cancelled by the adapter', () async {
      final h = _Harness((o, i) {
        throw DioException.requestCancelled(requestOptions: o, reason: 'x');
      }, retryIf: (_) => true);
      await expectLater(
        h.dio.get<dynamic>('/r'),
        throwsA(isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.cancel)),
      );
      expect(h.adapter.calls, 1);
    });

    test('a request whose token is cancelled during the backoff wait',
        () async {
      final token = CancelToken();
      final adapter = FakeAdapter((o, i) => jsonBody({}, status: 503));
      final dio = fakeDio(adapter);
      final sleeping = Completer<void>();
      dio.interceptors.add(RetryInterceptor(
        dio: dio,
        sleep: (d) {
          sleeping.complete();
          return Completer<void>().future; // never finishes on its own
        },
      ));
      final call = dio.get<dynamic>('/r', cancelToken: token);
      await sleeping.future;
      token.cancel('user left');
      await expectLater(
        call,
        throwsA(isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.cancel)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(adapter.calls, 1);
    });

    test('a streamed body', () async {
      final h = _Harness(_failThenOk(1));
      await expectLater(
        h.dio.put<dynamic>(
          '/upload',
          data: Stream.fromIterable([
            [1, 2, 3],
          ]),
          options: Options(headers: {Headers.contentLengthHeader: 3}),
        ),
        throwsA(_dioStatus(503)),
      );
      expect(h.adapter.calls, 1);
    });

    test('a FormData body', () async {
      final h = _Harness(_failThenOk(1));
      await expectLater(
        h.dio.put<dynamic>('/upload', data: FormData.fromMap({'a': 'b'})),
        throwsA(_dioStatus(503)),
      );
      expect(h.adapter.calls, 1);
    });
  });
}
