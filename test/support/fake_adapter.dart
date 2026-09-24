import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Decides what the fake server answers for one request.
typedef FakeHandler = FutureOr<ResponseBody> Function(
  RequestOptions options,
  int callIndex,
);

/// An in-memory [HttpClientAdapter]: no sockets, fully scripted.
///
/// Records every request that actually reached the "network" so tests can
/// count calls and inspect headers.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  final FakeHandler handler;
  final List<RequestOptions> requests = [];
  int cancelledFetches = 0;

  int get calls => requests.length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // Drain the body so FormData / streams behave as with a real client.
    if (requestStream != null) await requestStream.drain<void>();
    final index = requests.length;
    requests.add(options);
    final result = Future.value(handler(options, index));
    if (cancelFuture == null) return result;
    return Future.any([
      result,
      cancelFuture.then<ResponseBody>((_) {
        cancelledFetches++;
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: 'adapter cancelled',
        );
      }),
    ]);
  }

  @override
  void close({bool force = false}) {}
}

/// A JSON response body.
ResponseBody jsonBody(
  Object? json, {
  int status = 200,
  Map<String, List<String>> headers = const {},
}) {
  return ResponseBody.fromString(
    jsonEncode(json),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
      ...headers,
    },
  );
}

/// A plain-text response body with an explicit content type.
ResponseBody textBody(
  String text, {
  int status = 200,
  String contentType = 'text/plain',
  Map<String, List<String>> headers = const {},
}) {
  return ResponseBody.fromString(
    text,
    status,
    headers: {
      Headers.contentTypeHeader: [contentType],
      ...headers,
    },
  );
}

/// Builds a Dio wired to [adapter] with a fixed base URL.
Dio fakeDio(FakeAdapter adapter, {String baseUrl = 'https://api.test'}) {
  return Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter;
}

/// Builds an unsigned JWT with the given claims (signature is a dummy).
String makeJwt(Map<String, Object?> claims) {
  String part(Object json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part(claims)}.c2lnbmF0dXJl';
}

/// A controllable clock: [sleep] advances [now] instantly and records the
/// requested durations, so timing tests are exact and take no wall time.
class FakeClock {
  FakeClock([DateTime? start]) : now = start ?? DateTime.utc(2026, 1, 1);

  DateTime now;
  final List<Duration> sleeps = [];

  DateTime call() => now;

  Future<void> sleep(Duration d) async {
    sleeps.add(d);
    now = now.add(d);
  }
}
