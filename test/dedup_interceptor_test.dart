import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio_essentials/dio_essentials.dart';
import 'package:test/test.dart';

import 'support/fake_adapter.dart';

class _Harness {
  _Harness({
    Duration cacheTtl = Duration.zero,
    DedupKeyBuilder? keyBuilder,
    bool gated = false,
    int status = 200,
  }) {
    if (gated) gate = Completer<void>();
    adapter = FakeAdapter((o, i) async {
      if (gate != null) await gate!.future;
      return jsonBody({
        'call': i,
        'path': o.path,
        'list': [1, 2],
      }, status: status);
    });
    dio = fakeDio(adapter);
    dio.interceptors.add(DedupInterceptor(
      dio: dio,
      cacheTtl: cacheTtl,
      keyBuilder: keyBuilder,
      clock: clock.call,
    ));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      downstream++;
      h.next(o);
    }));
  }

  final clock = FakeClock();
  Completer<void>? gate;
  late final FakeAdapter adapter;
  late final Dio dio;
  int downstream = 0;

  /// Lets queued requests reach the adapter before the gate opens.
  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> release() async {
    await settle();
    gate!.complete();
  }
}

const _optIn = {DedupInterceptor.extraKey: true};

void main() {
  group('in-flight coalescing', () {
    test('5 identical concurrent GETs fan out from one network call', () async {
      final h = _Harness(gated: true);
      final calls = List.generate(5, (_) => h.dio.get<dynamic>('/items'));
      await h.release();
      final results = await Future.wait(calls);

      expect(h.adapter.calls, 1);
      expect(h.downstream, 1, reason: 'later interceptors see one request');
      for (final r in results) {
        expect(r.statusCode, 200);
        expect(r.data, containsPair('call', 0));
      }
    });

    test('each waiter gets a response bound to its own RequestOptions',
        () async {
      final h = _Harness(gated: true);
      final a =
          h.dio.get<dynamic>('/items', options: Options(extra: {'id': 'a'}));
      final b =
          h.dio.get<dynamic>('/items', options: Options(extra: {'id': 'b'}));
      await h.release();
      expect((await a).requestOptions.extra['id'], 'a');
      expect((await b).requestOptions.extra['id'], 'b');
    });

    test('waiters get independent copies of the decoded JSON', () async {
      final h = _Harness(gated: true);
      final a = h.dio.get<dynamic>('/items');
      final b = h.dio.get<dynamic>('/items');
      await h.release();
      final ra = await a;
      final rb = await b;
      (ra.data as Map)['call'] = 'mutated';
      ((ra.data as Map)['list'] as List).add(3);
      expect((rb.data as Map)['call'], 0);
      expect((rb.data as Map)['list'], [1, 2]);
    });

    test('an error fans out to every waiter', () async {
      final h = _Harness(gated: true, status: 500);
      final calls = List.generate(
        3,
        (_) => h.dio.get<dynamic>('/items').then<Object?>(
              (r) => r,
              onError: (Object e) => e,
            ),
      );
      await h.release();
      final results = await Future.wait(calls);
      expect(h.adapter.calls, 1);
      for (final e in results) {
        expect(
          e,
          isA<DioException>()
              .having((e) => e.response?.statusCode, 'status', 500),
        );
      }
    });

    test('a request after the flight completes goes to the network again',
        () async {
      final h = _Harness();
      await h.dio.get<dynamic>('/items');
      await h.dio.get<dynamic>('/items');
      expect(h.adapter.calls, 2);
    });
  });

  group('key', () {
    test('different query parameters are different requests', () async {
      final h = _Harness(gated: true);
      final a = h.dio.get<dynamic>('/items', queryParameters: {'page': 1});
      final b = h.dio.get<dynamic>('/items', queryParameters: {'page': 2});
      await h.release();
      await Future.wait([a, b]);
      expect(h.adapter.calls, 2);
    });

    test('query parameter order does not matter', () async {
      final h = _Harness(gated: true);
      final a = h.dio.get<dynamic>('/items', queryParameters: {'a': 1, 'b': 2});
      final b = h.dio.get<dynamic>('/items', queryParameters: {'b': 2, 'a': 1});
      await h.release();
      await Future.wait([a, b]);
      expect(h.adapter.calls, 1);
    });

    test('a different Authorization header is a different request', () async {
      final h = _Harness(gated: true);
      final a = h.dio.get<dynamic>('/me',
          options: Options(headers: {'Authorization': 'Bearer A'}));
      final b = h.dio.get<dynamic>('/me',
          options: Options(headers: {'authorization': 'Bearer B'}));
      await h.release();
      await Future.wait([a, b]);
      expect(h.adapter.calls, 2);
    });

    test('headers outside the key do not split requests', () async {
      final h = _Harness(gated: true);
      final a = h.dio
          .get<dynamic>('/me', options: Options(headers: {'X-Trace': '1'}));
      final b = h.dio
          .get<dynamic>('/me', options: Options(headers: {'X-Trace': '2'}));
      await h.release();
      await Future.wait([a, b]);
      expect(h.adapter.calls, 1);
    });

    test('the body is part of the key', () async {
      final h = _Harness(gated: true);
      final a = h.dio.post<dynamic>('/sync',
          data: {
            'ids': [1]
          },
          options: Options(extra: _optIn));
      final b = h.dio.post<dynamic>('/sync',
          data: {
            'ids': [1, 2]
          },
          options: Options(extra: _optIn));
      final c = h.dio.post<dynamic>('/sync',
          data: {
            'ids': [1]
          },
          options: Options(extra: _optIn));
      await h.release();
      await Future.wait([a, b, c]);
      expect(h.adapter.calls, 2);
    });

    test('a custom key builder replaces the default', () async {
      final h = _Harness(gated: true, keyBuilder: (o) => o.path);
      final a = h.dio.get<dynamic>('/items', queryParameters: {'page': 1});
      final b = h.dio.get<dynamic>('/items', queryParameters: {'page': 2});
      await h.release();
      await Future.wait([a, b]);
      expect(h.adapter.calls, 1);
    });

    test('a key builder returning null bypasses deduplication', () async {
      final h = _Harness(gated: true, keyBuilder: (o) => null);
      final a = h.dio.get<dynamic>('/items');
      final b = h.dio.get<dynamic>('/items');
      await h.release();
      await Future.wait([a, b]);
      expect(h.adapter.calls, 2);
    });

    test('defaultKey is stable and includes method, URI, headers and body', () {
      RequestOptions o(String method, {Object? data, String auth = 'x'}) =>
          RequestOptions(
            method: method,
            baseUrl: 'https://api.test',
            path: '/p',
            data: data,
            headers: {'authorization': auth},
          );
      final k = DedupInterceptor.defaultKey;
      expect(k(o('GET')), k(o('GET')));
      expect(k(o('GET')), isNot(k(o('HEAD'))));
      expect(k(o('GET', auth: 'y')), isNot(k(o('GET'))));
      expect(k(o('POST', data: 'a')), isNot(k(o('POST', data: 'b'))));
      expect(k(o('POST', data: FormData())), isNull);
      expect(k(o('POST', data: const Stream<List<int>>.empty())), isNull);
    });
  });

  group('cancellation', () {
    test('cancelling one waiter does not cancel the others', () async {
      final h = _Harness(gated: true);
      final token = CancelToken();
      final cancelled = h.dio.get<dynamic>('/items', cancelToken: token);
      final others = List.generate(3, (_) => h.dio.get<dynamic>('/items'));
      await h.settle();
      token.cancel('gone');
      await expectLater(
        cancelled,
        throwsA(isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.cancel)),
      );
      h.gate!.complete();
      final results = await Future.wait(others);
      expect(results.map((r) => r.statusCode), [200, 200, 200]);
      expect(h.adapter.calls, 1);
      expect(h.adapter.cancelledFetches, 0);
    });

    test('cancelling a later waiter does not affect the first', () async {
      final h = _Harness(gated: true);
      final first = h.dio.get<dynamic>('/items');
      final token = CancelToken();
      final second = h.dio.get<dynamic>('/items', cancelToken: token);
      await h.settle();
      token.cancel();
      await expectLater(second, throwsA(isA<DioException>()));
      h.gate!.complete();
      expect((await first).statusCode, 200);
      expect(h.adapter.cancelledFetches, 0);
    });

    test('when every waiter cancels, the shared request is cancelled',
        () async {
      final h = _Harness(gated: true);
      final t1 = CancelToken();
      final t2 = CancelToken();
      final a = h.dio.get<dynamic>('/items', cancelToken: t1);
      final b = h.dio.get<dynamic>('/items', cancelToken: t2);
      await h.settle();
      t1.cancel();
      t2.cancel();
      await expectLater(a, throwsA(isA<DioException>()));
      await expectLater(b, throwsA(isA<DioException>()));
      await h.settle();
      expect(h.adapter.cancelledFetches, 1);

      // A fresh request does not join the cancelled flight.
      h.gate!.complete();
      final c = await h.dio.get<dynamic>('/items');
      expect(c.statusCode, 200);
      expect(h.adapter.calls, 2);
    });
  });

  group('short-lived cache', () {
    test('is off by default', () async {
      final h = _Harness();
      await h.dio.get<dynamic>('/items');
      await h.dio.get<dynamic>('/items');
      expect(h.adapter.calls, 2);
    });

    test('serves GET from cache within the TTL and refetches after', () async {
      final h = _Harness(cacheTtl: const Duration(seconds: 5));
      await h.dio.get<dynamic>('/items');
      h.clock.now = h.clock.now.add(const Duration(seconds: 4));
      final cached = await h.dio.get<dynamic>('/items');
      expect(h.adapter.calls, 1);
      expect(cached.data, containsPair('call', 0));

      h.clock.now = h.clock.now.add(const Duration(seconds: 2));
      final fresh = await h.dio.get<dynamic>('/items');
      expect(h.adapter.calls, 2);
      expect(fresh.data, containsPair('call', 1));
    });

    test('a cache hit does not extend the expiry', () async {
      final h = _Harness(cacheTtl: const Duration(seconds: 5));
      await h.dio.get<dynamic>('/items'); // t=0, expires t=5
      for (var t = 0; t < 4; t++) {
        h.clock.now = h.clock.now.add(const Duration(seconds: 1));
        await h.dio.get<dynamic>('/items');
      }
      h.clock.now = h.clock.now.add(const Duration(seconds: 2)); // t=6
      await h.dio.get<dynamic>('/items');
      expect(h.adapter.calls, 2);
    });

    test('caches HEAD too', () async {
      final h = _Harness(cacheTtl: const Duration(seconds: 5));
      await h.dio.head<dynamic>('/items');
      await h.dio.head<dynamic>('/items');
      expect(h.adapter.calls, 1);
    });

    test('cached data is a copy callers cannot poison', () async {
      final h = _Harness(cacheTtl: const Duration(seconds: 5));
      final first = await h.dio.get<dynamic>('/items');
      (first.data as Map)['call'] = 'poison';
      final second = await h.dio.get<dynamic>('/items');
      expect((second.data as Map)['call'], 0);
      // Mutating a cache hit must not leak into the next hit either.
      (second.data as Map)['call'] = 'poison again';
      final third = await h.dio.get<dynamic>('/items');
      expect((third.data as Map)['call'], 0);
      expect(third.data, isA<Map<String, dynamic>>());
      expect(h.adapter.calls, 1);
    });

    test('error responses are not cached', () async {
      final h = _Harness(cacheTtl: const Duration(seconds: 5), status: 500);
      await expectLater(h.dio.get<dynamic>('/items'), throwsA(anything));
      await expectLater(h.dio.get<dynamic>('/items'), throwsA(anything));
      expect(h.adapter.calls, 2);
    });

    for (final method in ['POST', 'PUT', 'PATCH', 'DELETE']) {
      test('$method is never cached or replayed', () async {
        final h = _Harness(cacheTtl: const Duration(seconds: 5));
        final opts = Options(method: method, extra: _optIn);
        await h.dio.request<dynamic>('/sync', data: {'a': 1}, options: opts);
        await h.dio.request<dynamic>('/sync', data: {'a': 1}, options: opts);
        expect(h.adapter.calls, 2);
      });
    }

    test('a write invalidates cached reads', () async {
      final h = _Harness(cacheTtl: const Duration(seconds: 5));
      await h.dio.get<dynamic>('/items');
      await h.dio.post<dynamic>('/items', data: {'n': 1});
      await h.dio.get<dynamic>('/items');
      expect(h.adapter.calls, 3);
    });

    test('clearCache drops cached responses', () async {
      final adapter = FakeAdapter((o, i) => jsonBody({'call': i}));
      final dio = fakeDio(adapter);
      final dedup = DedupInterceptor(
        dio: dio,
        cacheTtl: const Duration(minutes: 1),
      );
      dio.interceptors.add(dedup);
      await dio.get<dynamic>('/items');
      dedup.clearCache();
      await dio.get<dynamic>('/items');
      expect(adapter.calls, 2);
    });
  });

  group('writes and opt-outs', () {
    test('concurrent identical POSTs are not merged by default', () async {
      final h = _Harness(gated: true);
      final a = h.dio.post<dynamic>('/sync', data: {'a': 1});
      final b = h.dio.post<dynamic>('/sync', data: {'a': 1});
      await h.release();
      await Future.wait([a, b]);
      expect(h.adapter.calls, 2);
    });

    test('concurrent identical POSTs merge when opted in', () async {
      final h = _Harness(gated: true);
      final a = h.dio.post<dynamic>('/sync',
          data: {'a': 1}, options: Options(extra: _optIn));
      final b = h.dio.post<dynamic>('/sync',
          data: {'a': 1}, options: Options(extra: _optIn));
      await h.release();
      await Future.wait([a, b]);
      expect(h.adapter.calls, 1);
    });

    test('a GET can opt out', () async {
      final h = _Harness(gated: true);
      final opts = Options(extra: {DedupInterceptor.extraKey: false});
      final a = h.dio.get<dynamic>('/items', options: opts);
      final b = h.dio.get<dynamic>('/items', options: opts);
      await h.release();
      await Future.wait([a, b]);
      expect(h.adapter.calls, 2);
    });

    test('FormData bodies are never merged', () async {
      final h = _Harness(gated: true);
      final a = h.dio.post<dynamic>('/up',
          data: FormData.fromMap({'a': 'b'}), options: Options(extra: _optIn));
      final b = h.dio.post<dynamic>('/up',
          data: FormData.fromMap({'a': 'b'}), options: Options(extra: _optIn));
      await h.release();
      await Future.wait([a, b]);
      expect(h.adapter.calls, 2);
    });

    test('stream responses are never merged', () async {
      final h = _Harness(gated: true);
      final opts = Options(responseType: ResponseType.stream);
      final a = h.dio.get<dynamic>('/file', options: opts);
      final b = h.dio.get<dynamic>('/file', options: opts);
      await h.release();
      await Future.wait([a, b]);
      expect(h.adapter.calls, 2);
    });
  });
}
